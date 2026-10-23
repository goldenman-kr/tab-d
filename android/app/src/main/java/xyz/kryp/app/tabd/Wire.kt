package xyz.kryp.app.tabd

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

object Wire {
    const val MAX_PACKET = 8 * 1024 * 1024
    data class Packet(val type: Int, val body: ByteArray)
    data class Frame(val epoch: Long, val sequence: Long, val pts: Long, val keyframe: Boolean, val bytes: ByteArray)

    fun read(input: DataInputStream): Packet {
        val size = input.readInt()
        if (size !in 1..MAX_PACKET) throw IOException("Invalid packet length")
        val type = input.readUnsignedByte()
        val body = ByteArray(size - 1)
        input.readFully(body)
        return Packet(type, body)
    }

    fun write(output: DataOutputStream, type: Int, body: ByteArray) {
        require(body.size < MAX_PACKET)
        output.writeInt(body.size + 1)
        output.writeByte(type)
        output.write(body)
        output.flush()
    }

    fun frame(bytes: ByteArray): Frame {
        if (bytes.size < 22) throw IOException("Incomplete video frame")
        val header = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        val epoch = header.int.toLong() and 0xffffffffL
        val sequence = header.long
        val pts = header.long
        val flags = header.get().toInt() and 0xff
        if (sequence < 0 || pts < 0 || flags and 0xfe != 0) throw IOException("Invalid video metadata")
        return Frame(epoch, sequence, pts, flags and 1 != 0, bytes.copyOfRange(21, bytes.size))
    }
}
