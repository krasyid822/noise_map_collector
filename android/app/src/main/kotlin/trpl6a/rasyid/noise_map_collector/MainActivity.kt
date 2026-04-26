package trpl6a.rasyid.noise_map_collector

import android.content.Context
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "trpl6a.rasyid.noise_map_collector/content_resolver"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "resolveContentUri") {
                val uriString = call.argument<String>("uri")
                if (uriString != null) {
                    val path = resolveUri(uriString)
                    if (path != null) {
                        result.success(path)
                    } else {
                        result.error("UNAVAILABLE", "Could not resolve URI", null)
                    }
                } else {
                    result.error("INVALID_ARGUMENT", "URI is null", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun resolveUri(uriString: String): String? {
        return try {
            val uri = Uri.parse(uriString)
            val inputStream: InputStream? = contentResolver.openInputStream(uri)
            val fileName = getFileName(uri) ?: "temp_file.csv"
            val tempFile = File(cacheDir, fileName)
            
            inputStream?.use { input ->
                FileOutputStream(tempFile).use { output ->
                    input.copyTo(output)
                }
            }
            tempFile.absolutePath
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    private fun getFileName(uri: Uri): String? {
        var name: String? = null
        val cursor = contentResolver.query(uri, null, null, null, null)
        cursor?.use {
            if (it.moveToFirst()) {
                val index = it.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (index != -1) {
                    name = it.getString(index)
                }
            }
        }
        return name
    }
}
