package com.yokayo.music

import com.yokayo.music.audio.Analyzer
import com.yokayo.music.audio.BeatNet
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Сверка с iOS: папка с моно-сэмплами 11025 Гц (*.f32) из переменной YOKAYO_F32. */
class BeatNetTest {
    @Test fun matchesIos() {
        val dir = System.getenv("YOKAYO_F32") ?: return
        BeatNet.loadBytes(File("src/main/assets/BeatNet.bin").readBytes())
        File(dir).listFiles { f -> f.extension == "f32" }!!.sorted().forEach { f ->
            val bb = ByteBuffer.wrap(f.readBytes()).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
            val x = FloatArray(bb.remaining()).also { bb.get(it) }
            val t0 = System.currentTimeMillis()
            val a = Analyzer.compute(x)
            println("KT ${f.nameWithoutExtension} %.2f %.4f %.2f %s intro%d outro%d %dms".format(a.bpm, a.firstBeat, a.confidence, a.camelot, a.introEndBar, a.outroStartBar, System.currentTimeMillis() - t0))
        }
    }
}
