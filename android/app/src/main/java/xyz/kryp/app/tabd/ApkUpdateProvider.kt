package xyz.kryp.app.tabd

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

/** Only the verified, completed APK is exposed, temporarily and read-only. */
class ApkUpdateProvider : ContentProvider() {
    override fun onCreate() = true
    private fun file(uri: Uri): File {
        require(uri.authority == "${context!!.packageName}.updates" && uri.path == "/update.apk" && uri.query == null)
        return File(context!!.cacheDir, "updates/update.apk").also { require(it.isFile) }
    }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        require(mode == "r")
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }
    override fun getType(uri: Uri): String { file(uri); return "application/vnd.android.package-archive" }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val apk = file(uri)
        val columns = (projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE))
            .filter { it == OpenableColumns.DISPLAY_NAME || it == OpenableColumns.SIZE }.toTypedArray()
        return MatrixCursor(columns, 1).apply { addRow(columns.map { if (it == OpenableColumns.SIZE) apk.length() else "Mr-Tab-D-update.apk" }) }
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
}
