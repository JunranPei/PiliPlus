package com.personal.piliplus

import org.junit.Assert.*
import org.junit.Test

class PipFrameGateTest {
    @Test fun oldLiveFramesRemainValidUntilNewSizedSceneActuallyArrives() {
        val gate = PipFrameGate()
        val full = gate.request(1080, 2400, false)
        assertEquals(full, gate.resolve(1080, 2401, full.epoch))
        val small = gate.request(598, 336, true)
        assertEquals(full, gate.resolve(1080, 2401, null))
        assertNull(gate.resolve(598, 337, full.epoch))
        assertEquals(small, gate.resolve(598, 337, small.epoch))
        assertNull(gate.resolve(1080, 2401, full.epoch))
        gate.cancel()
        assertNull(gate.resolve(598, 337, null))
    }
    @Test fun rootConstraintsMatchPhysicalBoundsForBothDirections() {
        for (request in listOf(PipFrameGate.Request(1, 598, 336, true), PipFrameGate.Request(2, 1080, 2400, false))) {
            for (marker in listOf(true, false)) {
                val metrics = PipFrameMetrics.create(request, 2.625f, marker)
                assertEquals(request.width, metrics.width)
                assertEquals(if (marker) request.height + 1 else request.height, metrics.height)
                assertEquals(metrics.width, metrics.minWidth)
                assertEquals(metrics.width, metrics.maxWidth)
                assertEquals(metrics.height, metrics.minHeight)
                assertEquals(metrics.height, metrics.maxHeight)
            }
        }
    }
    @Test fun dimensionsWithoutRenderedGenerationAreInsufficient() {
        val gate = PipFrameGate()
        val request = gate.request(598, 336, true)
        assertFalse(gate.accepts(request.epoch, 598, 337, null))
        assertFalse(gate.accepts(request.epoch, 598, 337, request.epoch + 1))
        assertFalse(gate.accepted)
        assertTrue(gate.accepts(request.epoch, 598, 337, request.epoch))
        assertTrue(gate.accepts(request.epoch, 598, 337, null))
    }

    @Test fun resizingAndReturningInvalidateQueuedOldFrames() {
        val gate = PipFrameGate()
        val small = gate.request(598, 336, true)
        val normal = gate.request(1080, 2400, false)
        assertFalse(gate.accepts(small.epoch, 598, 337, small.epoch))
        assertFalse(gate.accepts(normal.epoch, 598, 337, normal.epoch))
        assertFalse(gate.accepts(normal.epoch, 1080, 2400, normal.epoch))
        assertTrue(gate.accepts(normal.epoch, 1080, 2401, normal.epoch))
        gate.cancel()
        assertFalse(gate.accepts(normal.epoch, 1080, 2401, normal.epoch))
    }

    @Test fun markerRequiresMagicAndComplement() {
        assertEquals(123, PipFrameGate.decode(PipFrameGate.MAGIC, 123, 123 xor 0xFFFFFF))
        assertNull(PipFrameGate.decode(0, 123, 123 xor 0xFFFFFF))
        assertNull(PipFrameGate.decode(PipFrameGate.MAGIC, 123, 124 xor 0xFFFFFF))
    }
}
