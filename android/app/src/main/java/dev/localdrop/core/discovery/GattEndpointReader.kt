package dev.localdrop.core.discovery

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.util.Log
import dev.localdrop.core.crypto.DecryptionException
import dev.localdrop.core.presence.PresenceCrypto
import dev.localdrop.core.protocol.CborException
import dev.localdrop.core.protocol.EndpointInfo
import dev.localdrop.core.protocol.ProtocolConstants
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.TimeoutCancellationException

/** Why reading Endpoint Info over GATT failed. */
sealed class GattReadException(message: String) : Exception(message) {
    class ConnectionFailed(val status: Int) : GattReadException("GATT connection failed (status $status)")
    class Disconnected : GattReadException("Device disconnected during GATT read")
    class ServiceNotFound : GattReadException("LocalDrop GATT service not found")
    class ReadFailed(val status: Int) : GattReadException("Characteristic read failed (status $status)")
    class Timeout : GattReadException("GATT read timed out")
    class Malformed(cause: CborException) : GattReadException("Malformed endpoint info: ${cause.message}")
    class PermissionDenied(cause: SecurityException) : GattReadException("Bluetooth permission denied: ${cause.message}")
}

/**
 * Connects to a LocalDrop peripheral, reads the Endpoint Info characteristic and disconnects.
 * Reads are serialized: many Android BLE stacks misbehave with parallel GATT connections.
 */
class GattEndpointReader(private val context: Context) {

    private val mutex = Mutex()

    /**
     * @param presenceKey opens a sealed (private-mode) value; null accepts only the open
     *   pairing-mode form.
     */
    suspend fun read(device: BluetoothDevice, presenceKey: ByteArray? = null): EndpointInfo = mutex.withLock {
        var lastError: GattReadException? = null
        repeat(MAX_ATTEMPTS) { attempt ->
            try {
                return@withLock readOnce(device, presenceKey)
            } catch (e: GattReadException) {
                lastError = e
                // A first connection that hangs is common (Mi A2 and others); a fresh attempt usually works.
                val retryable = e is GattReadException.ConnectionFailed || e is GattReadException.Disconnected ||
                    e is GattReadException.Timeout
                Log.w(TAG, "GATT read attempt ${attempt + 1}/$MAX_ATTEMPTS failed: ${e.message}")
                if (!retryable) throw e
                if (attempt < MAX_ATTEMPTS - 1) delay(RETRY_DELAY_MS)
            }
        }
        throw lastError ?: GattReadException.Timeout()
    }

    // Permission is checked by BluetoothEnvironment before discovery runs; a revocation in the
    // meantime throws SecurityException, which is mapped to PermissionDenied below.
    @SuppressLint("MissingPermission")
    private suspend fun readOnce(device: BluetoothDevice, presenceKey: ByteArray?): EndpointInfo {
        val result = CompletableDeferred<ByteArray>()

        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                when {
                    status != BluetoothGatt.GATT_SUCCESS ->
                        result.completeExceptionally(GattReadException.ConnectionFailed(status))
                    newState == BluetoothProfile.STATE_CONNECTED -> {
                        // A larger MTU makes the long read finish in one or two round trips.
                        if (!gatt.requestMtu(REQUESTED_MTU)) gatt.discoverServices()
                    }
                    newState == BluetoothProfile.STATE_DISCONNECTED ->
                        result.completeExceptionally(GattReadException.Disconnected())
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                Log.d(TAG, "MTU changed to $mtu (status $status)")
                if (!gatt.discoverServices()) result.completeExceptionally(GattReadException.ServiceNotFound())
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                val characteristic = gatt.getService(ProtocolConstants.SERVICE_UUID)
                    ?.getCharacteristic(ProtocolConstants.ENDPOINT_INFO_CHARACTERISTIC_UUID)
                if (status != BluetoothGatt.GATT_SUCCESS || characteristic == null) {
                    result.completeExceptionally(GattReadException.ServiceNotFound())
                    return
                }
                if (!gatt.readCharacteristic(characteristic)) {
                    result.completeExceptionally(GattReadException.ReadFailed(BluetoothGatt.GATT_FAILURE))
                }
            }

            // API 33+
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) = complete(status, value)

            // API 30–32
            @Deprecated("Replaced on API 33 by the overload that receives the value")
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                @Suppress("DEPRECATION")
                complete(status, characteristic.value ?: ByteArray(0))
            }

            private fun complete(status: Int, value: ByteArray) {
                if (status == BluetoothGatt.GATT_SUCCESS) result.complete(value)
                else result.completeExceptionally(GattReadException.ReadFailed(status))
            }
        }

        val gatt = try {
            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: SecurityException) {
            throw GattReadException.PermissionDenied(e)
        } ?: throw GattReadException.ConnectionFailed(BluetoothGatt.GATT_FAILURE)

        try {
            val bytes = withTimeout(READ_TIMEOUT_MS) { result.await() }
            return try {
                EndpointInfo.decode(bytes, presenceKey?.let { key -> { sealed -> openSealed(key, sealed) } })
            } catch (e: CborException) {
                throw GattReadException.Malformed(e)
            }
        } catch (e: TimeoutCancellationException) {
            throw GattReadException.Timeout()
        } catch (e: SecurityException) {
            throw GattReadException.PermissionDenied(e)
        } finally {
            try {
                gatt.disconnect()
                gatt.close()
            } catch (e: SecurityException) {
                Log.w(TAG, "Closing GATT without permission: ${e.message}")
            }
        }
    }

    private fun openSealed(key: ByteArray, sealed: ByteArray): ByteArray = try {
        PresenceCrypto.openEndpoint(key, sealed)
    } catch (e: DecryptionException) {
        // A rotated presence key (after the Mac forgot another device) can't open it anymore.
        throw CborException("sealed endpoint info doesn't open with the stored presence key")
    }

    private companion object {
        const val TAG = "LD/discovery"
        const val REQUESTED_MTU = 247
        /** A successful read takes 1–4 s; waiting longer only delays the retry that usually succeeds. */
        const val READ_TIMEOUT_MS = 5_000L
        const val MAX_ATTEMPTS = 3
        const val RETRY_DELAY_MS = 1_000L
    }
}
