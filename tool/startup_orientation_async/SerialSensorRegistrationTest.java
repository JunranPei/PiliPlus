package com.github.rmtmckenzie.native_device_orientation;

import java.util.ArrayDeque;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public final class SerialSensorRegistrationTest {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    public static void main(String[] args) throws Exception {
        ExecutorService worker = Executors.newSingleThreadExecutor();
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch finish = new CountDownLatch(1);
        AtomicInteger registrations = new AtomicInteger();
        AtomicInteger releases = new AtomicInteger();
        AtomicInteger errors = new AtomicInteger();
        SerialSensorRegistration lease = new SerialSensorRegistration(worker,
            new SerialSensorRegistration.Backend() {
                public boolean register() {
                    if (registrations.incrementAndGet() == 1) {
                        entered.countDown();
                        try { check(finish.await(3, TimeUnit.SECONDS), "registration test timed out"); }
                        catch (InterruptedException error) { throw new RuntimeException(error); }
                    }
                    return true;
                }
                public void unregister() { releases.incrementAndGet(); }
            }, error -> errors.incrementAndGet());
        try {
            lease.enable();
            check(entered.await(2, TimeUnit.SECONDS), "worker did not enter register");
            lease.disable(); // Must return while the backend remains blocked.
            check(!lease.acceptsEvents(), "cancelled registration accepted an event");
            lease.enable(); // New generation queued behind the cancelled one.
            check(!lease.acceptsEvents(), "new generation accepted old events");
            finish.countDown();
            worker.submit(() -> {}).get(2, TimeUnit.SECONDS);
            check(registrations.get() == 2 && releases.get() == 1, "late registration leaked or restart lost");
            check(lease.acceptsEvents(), "restart failed to accept current events");
            lease.enable();
            worker.submit(() -> {}).get(2, TimeUnit.SECONDS);
            check(registrations.get() == 2, "duplicate enable registered twice");
            lease.disable();
            check(!lease.acceptsEvents(), "disable did not immediately reject events");
            worker.submit(() -> {}).get(2, TimeUnit.SECONDS);
            check(releases.get() == 2 && errors.get() == 0, "release failed");
        } finally {
            finish.countDown();
            worker.shutdownNow();
        }
        ArrayDeque<Runnable> queue = new ArrayDeque<>();
        AtomicInteger attempted = new AtomicInteger();
        SerialSensorRegistration skipped = new SerialSensorRegistration(queue::add,
            new SerialSensorRegistration.Backend() {
                public boolean register() { attempted.incrementAndGet(); return false; }
                public void unregister() { throw new AssertionError("unsuccessful registration released"); }
            }, error -> { throw new AssertionError(error); });
        skipped.enable(); skipped.disable();
        while (!queue.isEmpty()) queue.remove().run();
        check(attempted.get() == 0 && !skipped.acceptsEvents(), "queued cancellation failed");
        skipped.enable();
        while (!queue.isEmpty()) queue.remove().run();
        check(attempted.get() == 1 && !skipped.acceptsEvents(), "false registration accepted events");
        AtomicInteger failedRelease = new AtomicInteger();
        SerialSensorRegistration failed = new SerialSensorRegistration(queue::add,
            new SerialSensorRegistration.Backend() {
                public boolean register() { throw new IllegalStateException("injected failure"); }
                public void unregister() { failedRelease.incrementAndGet(); }
            }, error -> errors.incrementAndGet());
        failed.enable();
        while (!queue.isEmpty()) queue.remove().run();
        check(!failed.acceptsEvents() && errors.get() == 1 && failedRelease.get() == 1,
              "exception must clean up without activating callbacks");
        System.out.println("PASS: blocked cancel/restart, immediate callback guard, duplicate enable, queued cancel, false result, exception cleanup");
    }
}
