package com.github.rmtmckenzie.native_device_orientation;

import java.util.concurrent.Executor;
import java.util.function.Consumer;

/** Main-thread intent, serial worker ownership, and main-thread sensor delivery. */
final class SerialSensorRegistration {
    interface Backend {
        boolean register();
        void unregister();
    }

    private final Executor worker; // Must execute in FIFO order, never inline.
    private final Backend backend;
    private final Consumer<RuntimeException> onError;
    private volatile boolean wanted;
    private volatile long generation;
    private volatile long registeredGeneration = -1;
    private boolean registered; // Worker only.

    SerialSensorRegistration(Executor worker, Backend backend,
                             Consumer<RuntimeException> onError) {
        this.worker = worker;
        this.backend = backend;
        this.onError = onError;
    }

    // Called on the main thread, like the original plugin lifecycle methods.
    void enable() {
        if (wanted) return;
        wanted = true;
        final long current = ++generation;
        worker.execute(() -> {
            if (!isWanted(current)) return;
            try {
                registered = backend.register();
            } catch (RuntimeException error) {
                // A backend may have acquired a resource before throwing.
                registered = true;
                release();
                onError.accept(error);
                return;
            }
            if (!isWanted(current)) {
                release();
            } else if (registered) {
                registeredGeneration = current;
            }
        });
    }

    void disable() {
        if (!wanted) return;
        wanted = false;
        ++generation;
        registeredGeneration = -1;
        worker.execute(this::release);
    }

    boolean acceptsEvents() {
        return wanted && registeredGeneration == generation;
    }

    private boolean isWanted(long current) {
        return wanted && generation == current;
    }

    private void release() {
        registeredGeneration = -1;
        if (!registered) return;
        registered = false;
        try {
            backend.unregister();
        } catch (RuntimeException error) {
            onError.accept(error);
        }
    }
}
