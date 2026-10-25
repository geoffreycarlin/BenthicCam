package com.goprogps.gopro_gps_cam

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * "System pairing" channel. Some (mostly older) Android phones refuse a
 * Bluetooth LE connection to a GoPro that is not yet paired, failing at once
 * with GATT error 133. Pairing first fixes that — but only if Android knows
 * the camera is a Bluetooth LE device with a random address. A device object
 * made from the address alone is assumed to be "classic" Bluetooth and the
 * pairing silently fails, so we find the camera with our own LE scan first and
 * pair the device object that scan returns (as Android's Settings screen does).
 */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gopro_gps_cam/bond")
            .setMethodCallHandler { call, result ->
                try {
                    if (call.method == "openBluetoothSettings") {
                        startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    val address = call.argument<String>("address")
                    val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
                    if (address == null || adapter == null) {
                        result.error("unavailable", "Bluetooth not available", null)
                        return@setMethodCallHandler
                    }
                    when (call.method) {
                        // 10 = not paired, 11 = pairing, 12 = paired
                        "bondState" -> result.success(adapter.getRemoteDevice(address).bondState)
                        "bondLe" -> bondLe(adapter, address, result)
                        else -> result.notImplemented()
                    }
                } catch (e: SecurityException) {
                    result.error("permission", e.message, null)
                } catch (e: Exception) {
                    result.error("error", e.message, null)
                }
            }
    }

    /** Scans for the camera (max 10 s), then asks Android to pair with it.
     *  Replies "scanned", "address-only" (camera not seen; paired by address)
     *  or "failed". */
    private fun bondLe(adapter: android.bluetooth.BluetoothAdapter, address: String, result: MethodChannel.Result) {
        if (adapter.getRemoteDevice(address).bondState == BluetoothDevice.BOND_BONDED) {
            result.success("bonded")
            return
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            result.success(if (adapter.getRemoteDevice(address).createBond()) "address-only" else "failed")
            return
        }
        var done = false
        var bonding = false
        lateinit var cb: ScanCallback
        fun finish(reply: String) {
            if (done) return
            done = true
            try { scanner.stopScan(cb) } catch (_: Exception) {}
            main.post { result.success(reply) }
        }
        cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, r: ScanResult) {
                if (done || bonding) return
                bonding = true
                // Small pause after stopping the scan before pairing helps old stacks.
                try { scanner.stopScan(this) } catch (_: Exception) {}
                main.postDelayed({
                    val ok = try { r.device.createBond() } catch (_: Exception) { false }
                    finish(if (ok) "scanned" else "failed")
                }, 300)
            }
            override fun onScanFailed(errorCode: Int) {
                if (done || bonding) return
                bonding = true
                val ok = try { adapter.getRemoteDevice(address).createBond() } catch (_: Exception) { false }
                finish(if (ok) "address-only" else "failed")
            }
        }
        val filter = ScanFilter.Builder().setDeviceAddress(address).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(filter), settings, cb)
        main.postDelayed({
            if (!done && !bonding) {
                bonding = true
                val ok = try { adapter.getRemoteDevice(address).createBond() } catch (_: Exception) { false }
                finish(if (ok) "address-only" else "failed")
            }
        }, 10000)
    }
}
