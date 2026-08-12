package me.zhenxin.zmusic;

import java.lang.reflect.Method;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public final class JniSmokeTest {
    private static final ZMusicPlayer.EventListener NOOP_LISTENER = new ZMusicPlayer.EventListener() {
        public void onStateChanged(int state) {}
        public void onTrackEnded() {}
        public void onProgress(long positionMs, long durationMs) {}
        public void onError(String message) {}
        public void onBuffering(boolean buffering) {}
    };

    public static void main(String[] args) throws Exception {
        basicContract();
        invalidInputsAndHandles();
        multipleInstancesAreIsolated();
        destroyWhilePolling();
        destroyCancelsStalledDownload();
        repeatedLifecycle();
        System.out.println("JNI_SMOKE_OK");
    }

    private static void basicContract() throws Exception {
        ZMusicPlayer player = new ZMusicPlayer();
        try {
            require(player.getState() == 0, "初始状态必须为 stopped");
            require(player.setVolume(0.25f) == 0, "设置音量失败");
            require(Math.abs(player.getVolume() - 0.25f) < 0.001f, "音量读取不一致");
            player.enqueue("a.mp3", "A", "Artist");
            player.enqueueNext("b.mp3", null, null);
            require(player.getQueueSize() == 2, "队列大小不一致");
            require(player.getCurrentIndex() == 0, "初始队列索引不一致");
            player.removeFromQueue(1);
            require(player.getQueueSize() == 1, "移除队列项失败");
            player.setRepeatMode(2);
            player.setShuffle(true);
            player.loadLyrics("[00:00.00]中文😀");
            require("中文😀".equals(player.getCurrentLyric()), "Unicode 歌词往返失败");
            Method lyricAt = ZMusicPlayer.class.getDeclaredMethod(
                "nativeGetLyricLineAt", long.class, long.class);
            lyricAt.setAccessible(true);
            require("中文😀".equals(lyricAt.invoke(player, nativeHandle(player), 0L)),
                "指定时间歌词 JNI 往返失败");
            player.clearQueue();
            require(player.getQueueSize() == 0, "清空队列失败");
            require(player.play("/path/that/does/not/exist.mp3") == -1, "无效文件必须失败");
            require(player.getState() == 4, "解码失败后必须进入 error 状态");
        } finally {
            player.destroy();
            player.destroy();
        }
    }

    private static void invalidInputsAndHandles() throws Exception {
        ZMusicPlayer player = new ZMusicPlayer();
        try {
            require(player.play("") == -1, "空播放地址必须失败");
            require(player.seek(-1) == -1, "负数 seek 必须失败");
            player.removeFromQueue(-1);
            player.playAtIndex(-1);
            player.playNext();
            player.playPrevious();
            player.setRepeatMode(99);

            Method pause = ZMusicPlayer.class.getDeclaredMethod("nativePause", long.class);
            pause.setAccessible(true);
            require(((Integer) pause.invoke(player, Long.MAX_VALUE)) == -1,
                "任意无效句柄必须被拒绝");
        } finally {
            player.destroy();
        }
        require(player.pause() == -1, "destroy 后调用必须失败");
        require(player.getState() == 0, "destroy 后查询必须返回安全默认值");
    }

    private static void multipleInstancesAreIsolated() {
        ZMusicPlayer first = new ZMusicPlayer();
        ZMusicPlayer second = new ZMusicPlayer();
        try {
            require(first.setVolume(0.2f) == 0, "第一个实例设置音量失败");
            require(second.setVolume(0.8f) == 0, "第二个实例设置音量失败");
            first.enqueue("first.mp3", null, null);
            require(Math.abs(first.getVolume() - 0.2f) < 0.001f, "第一个实例音量串扰");
            require(Math.abs(second.getVolume() - 0.8f) < 0.001f, "第二个实例音量串扰");
            require(first.getQueueSize() == 1, "第一个实例队列异常");
            require(second.getQueueSize() == 0, "第二个实例队列串扰");
        } finally {
            first.destroy();
            second.destroy();
        }
    }

    private static long nativeHandle(ZMusicPlayer player) throws Exception {
        var handle = ZMusicPlayer.class.getDeclaredField("handle");
        handle.setAccessible(true);
        return handle.getLong(player);
    }

    private static void destroyWhilePolling() {
        for (int i = 0; i < 50; i++) {
            ZMusicPlayer player = new ZMusicPlayer();
            player.setEventListener(NOOP_LISTENER);
            player.setEventListener(NOOP_LISTENER);
            player.destroy();
        }
    }

    private static void destroyCancelsStalledDownload() throws Exception {
        try (ServerSocket server = new ServerSocket(0)) {
            CountDownLatch bodySent = new CountDownLatch(1);
            CountDownLatch releaseServer = new CountDownLatch(1);
            AtomicReference<Throwable> serverError = new AtomicReference<>();
            Thread serverThread = new Thread(() -> {
                try (Socket socket = server.accept()) {
                    int matched = 0;
                    byte[] terminator = "\r\n\r\n".getBytes(StandardCharsets.US_ASCII);
                    while (matched < terminator.length) {
                        int value = socket.getInputStream().read();
                        if (value < 0) break;
                        matched = value == terminator[matched] ? matched + 1 : 0;
                    }

                    byte[] body = streamingWav();
                    String headers = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\n"
                        + "Content-Length: " + (body.length * 4) + "\r\n"
                        + "Connection: close\r\n\r\n";
                    socket.getOutputStream().write(headers.getBytes(StandardCharsets.US_ASCII));
                    socket.getOutputStream().write(body);
                    socket.getOutputStream().flush();
                    bodySent.countDown();
                    releaseServer.await(5, TimeUnit.SECONDS);
                } catch (Throwable error) {
                    serverError.set(error);
                }
            });
            serverThread.start();

            ZMusicPlayer player = new ZMusicPlayer();
            try {
                require(player.play("http://127.0.0.1:" + server.getLocalPort() + "/audio.wav") == 0,
                    "停滞流播放初始化失败");
                require(bodySent.await(2, TimeUnit.SECONDS), "本地服务器未发送测试音频");
                long started = System.nanoTime();
                player.destroy();
                long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
                require(elapsedMs < 1000, "停滞流 destroy 超时: " + elapsedMs + "ms");
            } finally {
                player.destroy();
                releaseServer.countDown();
                serverThread.join();
            }
            if (serverError.get() != null) {
                throw new AssertionError("本地 HTTP 服务器失败", serverError.get());
            }
        }
    }

    private static void repeatedLifecycle() throws Exception {
        Path wav = Files.createTempFile("zmusic-jni-", ".wav");
        Files.write(wav, testWav());
        try {
            for (int i = 0; i < 1000; i++) {
                ZMusicPlayer player = new ZMusicPlayer();
                try {
                    require(player.play(wav.toString()) == 0, "生命周期播放失败: " + i);
                    require(player.stop() == 0, "生命周期停止失败: " + i);
                } finally {
                    player.destroy();
                }
            }
        } finally {
            Files.deleteIfExists(wav);
        }
    }

    private static byte[] testWav() {
        int sampleRate = 8000;
        int dataSize = sampleRate / 50 * 2;
        return wav(dataSize, dataSize);
    }

    private static byte[] streamingWav() {
        return wav(256 * 1024, 8000 * 2 * 60);
    }

    private static byte[] wav(int actualDataSize, int declaredDataSize) {
        int sampleRate = 8000;
        ByteBuffer wav = ByteBuffer.allocate(44 + actualDataSize).order(ByteOrder.LITTLE_ENDIAN);
        wav.put("RIFF".getBytes(StandardCharsets.US_ASCII));
        wav.putInt(36 + declaredDataSize);
        wav.put("WAVEfmt ".getBytes(StandardCharsets.US_ASCII));
        wav.putInt(16);
        wav.putShort((short) 1);
        wav.putShort((short) 1);
        wav.putInt(sampleRate);
        wav.putInt(sampleRate * 2);
        wav.putShort((short) 2);
        wav.putShort((short) 16);
        wav.put("data".getBytes(StandardCharsets.US_ASCII));
        wav.putInt(declaredDataSize);
        return wav.array();
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
