package dev.nrc.chat

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.core.content.FileProvider
import io.ktor.util.cio.readChannel
import kotlinx.coroutines.*
import java.io.File
import java.io.InputStream
import java.io.OutputStream

/** Android's document grants stay in this host; no broad storage permission or public file path. */
class AndroidAttachments(private val activity: ComponentActivity, private val chat: ChatClient,
                         private val scope: CoroutineScope) {
    data class Pending(val file: File, val upload: AttachmentUpload, val target: AttachmentTarget)
    var pending by mutableStateOf<Pending?>(null); private set
    var preparing by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null)
    private val directory = File(activity.cacheDir, "chat-transfers").apply { deleteRecursively(); mkdirs() }
    private var pickTarget: AttachmentTarget? = null
    private data class Download(val file: File, val target: AttachmentTarget, val name: String, val mime: String)
    private var savedFile: Download? = null
    private var operationJob: Job? = null
    private var openedFolder: File? = null

    private val picker = activity.registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val target = pickTarget
        pickTarget = null
        if (uri != null && target != null) stage(uri, target)
    }
    private val saver = activity.registerForActivityResult(object : ActivityResultContract<Download, Uri?>() {
        override fun createIntent(context: Context, input: Download) = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE).setType(input.mime).putExtra(Intent.EXTRA_TITLE, input.name)
        override fun parseResult(resultCode: Int, intent: Intent?) =
            if (resultCode == Activity.RESULT_OK) intent?.data else null
    }) { uri ->
        val selected = savedFile
        savedFile = null
        if (selected != null && uri != null && sameTarget(selected.target)) launchOperation {
            try {
                require(uri.scheme == "content")
                val context = currentCoroutineContext()
                runInterruptible(Dispatchers.IO) {
                    activity.contentResolver.openOutputStream(uri, "wt").use { output ->
                        checkNotNull(output)
                        selected.file.inputStream().use { copy(it, output) { context.ensureActive() } }
                    }
                }
            } catch (cancelled: CancellationException) {
                error = "Save cancelled. A partial file may remain at the chosen destination."
                throw cancelled
            }
            catch (_: Exception) { error = "Could not save the file. Check access and free storage." }
            finally { selected.file.parentFile?.deleteRecursively() }
        } else selected?.file?.parentFile?.deleteRecursively()
    }

    fun pick(image: Boolean) {
        val target = chat.attachmentTarget() ?: return
        if (preparing || pending != null || pickTarget != null || savedFile != null || chat.state.value.fileTransfer != null) return
        pickTarget = target
        picker.launch(arrayOf(if (image) "image/*" else "*/*"))
    }

    private fun sameTarget(target: AttachmentTarget) = chat.state.value.let {
        it.profile == target.profile && it.username == target.username && it.selected == target.conversationId
    }

    /** Keep the busy slot until streams and private files have actually been cleaned up. */
    private fun launchOperation(onFinished: (Boolean) -> Unit = {}, block: suspend () -> Unit) {
        check(operationJob == null)
        val job = scope.launch(start = CoroutineStart.LAZY) {
            var completed = false
            try { block(); completed = true }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { error = "Could not complete the file action. Check access and device storage." }
            finally {
                operationJob = null; preparing = false
                onFinished(completed && currentCoroutineContext().isActive)
            }
        }
        operationJob = job
        preparing = true
        job.start()
    }

    private fun copy(input: InputStream, output: OutputStream, checkActive: () -> Unit) {
        val buffer = ByteArray(32 * 1024)
        var count = 0L
        while (true) {
            checkActive()
            val n = input.read(buffer)
            if (n < 0) break
            count += n; require(count <= MAX_ATTACHMENT_BYTES)
            output.write(buffer, 0, n)
        }
    }

    private fun mime(value: String) = value.substringBefore(';').trim().lowercase().takeIf {
        Regex("[a-z0-9.+_-]+/[a-z0-9.+_-]+").matches(it)
    } ?: "application/octet-stream"

    private fun stage(uri: Uri, target: AttachmentTarget) {
        if (!sameTarget(target)) { error = "Chat or account changed. Select the file again."; return }
        launchOperation {
            val file = File(directory, "upload-${java.util.UUID.randomUUID()}.data")
            try {
                val context = currentCoroutineContext()
                val upload = runInterruptible(Dispatchers.IO) {
                    require(uri.scheme == "content")
                    var name = "attachment"
                    activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
                    }
                    name = name.substringAfterLast('/').substringAfterLast('\\').map { if (it.code < 32 || it.code == 127) '_' else it }.joinToString("").ifBlank { "attachment" }
                    require(name.toByteArray().size <= 1024)
                    val mime = mime(activity.contentResolver.getType(uri).orEmpty())
                    activity.contentResolver.openInputStream(uri).use { input ->
                        checkNotNull(input)
                        file.outputStream().use { output ->
                            copy(input, output) { context.ensureActive() }
                        }
                    }
                    AttachmentUpload(name, mime, file.length()) { context -> file.readChannel(coroutineContext = context + Dispatchers.IO) }
                }
                check(sameTarget(target))
                pending = Pending(file, upload, target)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { error = "Could not prepare the file. Maximum size is 100 MiB; check access and storage." }
            finally { if (pending?.file != file) file.delete() }
        }
    }

    fun dismiss() { pending?.file?.delete(); pending = null }

    fun send() {
        val selected = pending ?: return
        val job = chat.uploadAttachment(selected.target, selected.upload)
        if (job == null) { error = "Wait for this chat to reconnect, then try again."; return }
        pending = null
        job.invokeOnCompletion { selected.file.delete() }
    }

    fun receive(attachment: ChatAttachment, open: Boolean) {
        val target = chat.attachmentTarget() ?: return
        if (preparing || pending != null || pickTarget != null || savedFile != null || chat.state.value.fileTransfer != null) return
        var ready: Download? = null
        launchOperation(onFinished = { completed ->
            ready?.let { selected ->
                var handedOff = false
                try {
                    if (completed && sameTarget(selected.target)) {
                        if (open) {
                            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.files", selected.file, selected.name)
                            val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, selected.mime)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            activity.startActivity(Intent.createChooser(intent, "Open attachment"))
                            openedFolder = selected.file.parentFile
                        } else {
                            savedFile = selected
                            try { saver.launch(selected) } catch (error: Exception) { savedFile = null; throw error }
                        }
                        handedOff = true
                    }
                } catch (_: Exception) { error = "Could not open or save the attachment. A compatible app may be required." }
                finally { if (!handedOff) selected.file.parentFile?.deleteRecursively() }
            }
        }) {
            openedFolder?.deleteRecursively(); openedFolder = null
            // Never give different bytes a pathname that an earlier viewer still has a grant for.
            val folder = File(directory, "download/${java.util.UUID.randomUUID()}").apply { mkdirs() }
            val name = attachment.filename.substringAfterLast('/').substringAfterLast('\\').takeUnless { it == "." || it == ".." || it.isBlank() } ?: "attachment"
            val mime = mime(attachment.mimeType)
            val extension = name.substringAfterLast('.', "").takeIf { Regex("[A-Za-z0-9]{1,16}").matches(it) }
            val file = File(folder, "attachment${extension?.let { ".$it" }.orEmpty()}")
            var output: OutputStream? = null
            var downloaded = false
            var transfer: Job? = null
            try {
                withContext(Dispatchers.IO) { output = file.outputStream() }
                transfer = chat.downloadAttachment(target, attachment, write = { bytes, count ->
                    withContext(Dispatchers.IO) { checkNotNull(output).write(bytes, 0, count) }
                }, onComplete = { downloaded = true })
                if (transfer == null) error = "Another transfer is running, or this chat is offline."
                else transfer.join()
                currentCoroutineContext().ensureActive()
                if (downloaded && sameTarget(target)) ready = Download(file, target, name, mime)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { error = "Could not open or save the attachment. A compatible app may be required." }
            finally {
                withContext(NonCancellable) {
                    transfer?.cancelAndJoin()
                    withContext(Dispatchers.IO) {
                        try { output?.close() } catch (failure: Exception) { ready = null; throw failure }
                        finally { if (ready == null) folder.deleteRecursively() }
                    }
                }
            }
        }
    }

    fun cancel() { operationJob?.cancel(); chat.cancelFileTransfer() }

    // Preserve a waiting system-picker request across onStop; it is not an active copy.
    fun backgrounded() { cancel() }

    fun contextChanged() {
        cancel(); dismiss(); pickTarget = null
        savedFile?.file?.parentFile?.deleteRecursively(); savedFile = null
    }

    fun close() { contextChanged() }
}
