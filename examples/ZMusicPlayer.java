package me.zhenxin.zmusic;

/**
 * ZMusicPlayer JNI 测试程序
 *
 * <p>通过 JNI 桥接 Zig 层的播放引擎，提供完整的音乐播放器 Java 接口。
 * 包含播放控制、队列管理、歌词加载、事件回调等能力。
 * main 方法提供交互式演示流程。</p>
 *
 * @author 真心
 */
public class ZMusicPlayer {

    // 加载 Zig 编译生成的原生动态库
    static {
        System.loadLibrary("zmusic");
    }

    // 原生对象的句柄，用于在 JNI 调用中标识底层播放器实例
    private long handle;

    // ---- Native 方法声明 ----

    // --- 生命周期管理 ---
    // 创建和销毁底层播放器实例

    /** 初始化底层播放器，返回原生对象句柄 */
    private native long nativeInit();
    /** 销毁原生对象，释放底层资源 */
    private native void nativeDestroy(long handle);

    // --- 播放控制 ---
    // 播放、暂停、停止、恢复、跳转等核心操作

    /** 播放指定 URL 的音频 */
    private native int nativePlay(long handle, String url);
    /** 暂停当前播放 */
    private native int nativePause(long handle);
    /** 停止播放并重置状态 */
    private native int nativeStop(long handle);
    /** 从暂停位置恢复播放 */
    private native int nativeResume(long handle);
    /** 跳转到指定时间位置（毫秒） */
    private native int nativeSeek(long handle, long positionMs);

    // --- 状态查询 ---
    // 获取播放器当前状态和媒体信息

    /** 获取当前播放状态码 */
    private native int nativeGetState(long handle);
    /** 获取当前播放位置（毫秒） */
    private native long nativeGetPosition(long handle);
    /** 获取媒体总时长（毫秒） */
    private native long nativeGetDuration(long handle);
    /** 获取当前音量（0.0 ~ 1.0） */
    private native float nativeGetVolume(long handle);
    /** 设置音量（0.0 ~ 1.0） */
    private native int nativeSetVolume(long handle, float volume);

    // --- 队列操作 ---
    // 播放列表的增删改查和导航

    /** 将曲目追加到队列末尾 */
    private native void nativeEnqueue(long handle, String url, String title, String artist);
    /** 将曲目插入到当前播放曲目之后（"下一首播放"） */
    private native void nativeEnqueueNext(long handle, String url, String title, String artist);
    /** 移除队列中指定索引的曲目 */
    private native void nativeRemoveFromQueue(long handle, int index);
    /** 清空播放队列 */
    private native void nativeClearQueue(long handle);
    /** 跳到下一首曲目 */
    private native void nativePlayNext(long handle);
    /** 跳到上一首曲目 */
    private native void nativePlayPrevious(long handle);
    /** 跳到队列中指定索引的曲目 */
    private native void nativePlayAtIndex(long handle, int index);
    /** 获取队列中的曲目数量 */
    private native int nativeGetQueueSize(long handle);
    /** 获取当前播放曲目的索引 */
    private native int nativeGetCurrentIndex(long handle);

    // --- 歌词 ---
    // LRC 歌词的加载和查询

    /** 加载 LRC 格式的歌词内容 */
    private native void nativeLoadLyrics(long handle, String lrcContent);
    /** 获取当前时间对应的歌词行文本 */
    private native String nativeGetCurrentLyric(long handle);
    /** 获取指定时间点对应的歌词行文本 */
    private native String nativeGetLyricLineAt(long handle, long timeMs);

    // --- 模式控制 ---
    // 循环模式和随机播放

    /** 设置循环模式（0=不循环, 1=单曲循环, 2=列表循环） */
    private native void nativeSetRepeatMode(long handle, int mode);
    /** 启用或禁用随机播放 */
    private native void nativeSetShuffle(long handle, boolean enabled);

    // --- 事件轮询 ---
    // 从原生层拉取待处理的事件

    /** 轮询原生层的事件队列，返回事件类型码 */
    private native int nativePollEvent(long handle);

    // ---- 事件常量 ----
    // 与原生层事件类型一一对应，用于事件分发

    /** 无事件 */
    private static final int EVENT_NONE = 0;
    /** 播放状态变更 */
    private static final int EVENT_STATE_CHANGED = 1;
    /** 曲目播放结束 */
    private static final int EVENT_TRACK_ENDED = 2;
    /** 播放进度更新 */
    private static final int EVENT_PROGRESS_UPDATE = 3;
    /** 播放错误 */
    private static final int EVENT_ERROR = 4;
    /** 缓冲状态变更 */
    private static final int EVENT_BUFFERING = 5;

    // ---- 播放状态常量 ----
    // 与原生层 PlayerState 枚举对应

    /** 已停止 */
    private static final int STATE_STOPPED = 0;
    /** 加载中 */
    private static final int STATE_LOADING = 1;
    /** 正在播放 */
    private static final int STATE_PLAYING = 2;
    /** 已暂停 */
    private static final int STATE_PAUSED = 3;
    /** 错误状态 */
    private static final int STATE_ERROR = 4;

    // ---- 循环模式常量 ----

    /** 不循环 */
    private static final int REPEAT_NONE = 0;
    /** 单曲循环 */
    private static final int REPEAT_ONE = 1;
    /** 列表循环 */
    private static final int REPEAT_ALL = 2;

    // 轮询线程运行标志，volatile 确保多线程可见性
    private volatile boolean running = true;

    /**
     * 构造函数：初始化底层播放器。
     *
     * @throws RuntimeException 原生层初始化失败时抛出
     */
    public ZMusicPlayer() {
        handle = nativeInit();
        if (handle == 0) {
            throw new RuntimeException("ZMusicPlayer 初始化失败");
        }
    }

    /**
     * 销毁播放器，释放原生资源。
     * 先停止轮询线程，再销毁原生对象，避免竞态访问已释放的句柄。
     */
    public void destroy() {
        running = false;
        if (handle != 0) {
            nativeDestroy(handle);
            handle = 0;
        }
    }

    // ---- 公开 API ----
    // 薄封装层，隐藏 JNI handle 参数，对外提供简洁的 Java 接口

    /**
     * 播放指定 URL 的音频。
     *
     * @param url 音频资源的 URL（支持本地文件路径和网络地址）
     * @return 0 表示成功，非零表示错误码
     */
    public int play(String url) { return nativePlay(handle, url); }

    /**
     * 暂停当前播放。
     *
     * @return 0 表示成功，非零表示错误码
     */
    public int pause() { return nativePause(handle); }

    /**
     * 停止播放并释放音频资源。
     *
     * @return 0 表示成功，非零表示错误码
     */
    public int stop() { return nativeStop(handle); }

    /**
     * 恢复已暂停的播放。
     *
     * @return 0 表示成功，非零表示错误码
     */
    public int resume() { return nativeResume(handle); }

    /**
     * 跳转到指定播放位置。
     *
     * @param positionMs 目标位置（毫秒）
     * @return 0 表示成功，非零表示错误码
     */
    public int seek(long positionMs) { return nativeSeek(handle, positionMs); }

    /**
     * 获取当前播放状态。
     *
     * @return 状态码，参见 STATE_* 常量（0=停止, 1=加载中, 2=播放, 3=暂停, 4=错误）
     */
    public int getState() { return nativeGetState(handle); }

    /**
     * 获取当前播放位置。
     *
     * @return 当前位置（毫秒）
     */
    public long getPosition() { return nativeGetPosition(handle); }

    /**
     * 获取当前曲目的总时长。
     *
     * @return 总时长（毫秒）
     */
    public long getDuration() { return nativeGetDuration(handle); }

    /**
     * 获取当前音量。
     *
     * @return 音量值（0.0 ~ 1.0）
     */
    public float getVolume() { return nativeGetVolume(handle); }

    /**
     * 设置音量。
     *
     * @param volume 音量值（0.0 ~ 1.0）
     * @return 0 表示成功，非零表示错误码
     */
    public int setVolume(float volume) { return nativeSetVolume(handle, volume); }

    /**
     * 将曲目追加到播放队列末尾。
     *
     * @param url    音频资源 URL
     * @param title  曲目标题
     * @param artist 艺术家名称
     */
    public void enqueue(String url, String title, String artist) {
        nativeEnqueue(handle, url, title, artist);
    }

    /**
     * 将曲目插入到当前播放曲目之后（"下一首播放"）。
     *
     * @param url    音频资源 URL
     * @param title  曲目标题
     * @param artist 艺术家名称
     */
    public void enqueueNext(String url, String title, String artist) {
        nativeEnqueueNext(handle, url, title, artist);
    }

    /**
     * 移除播放队列中指定索引的曲目。
     *
     * @param index 要移除的曲目索引
     */
    public void removeFromQueue(int index) { nativeRemoveFromQueue(handle, index); }

    /** 清空播放队列中的所有曲目。 */
    public void clearQueue() { nativeClearQueue(handle); }

    /** 跳到下一首曲目。 */
    public void playNext() { nativePlayNext(handle); }

    /** 跳到上一首曲目。 */
    public void playPrevious() { nativePlayPrevious(handle); }

    /**
     * 跳到播放队列中指定索引的曲目并开始播放。
     *
     * @param index 目标曲目索引
     */
    public void playAtIndex(int index) { nativePlayAtIndex(handle, index); }

    /**
     * 获取播放队列中的曲目数量。
     *
     * @return 队列大小
     */
    public int getQueueSize() { return nativeGetQueueSize(handle); }

    /**
     * 获取当前播放曲目在队列中的索引。
     *
     * @return 当前索引
     */
    public int getCurrentIndex() { return nativeGetCurrentIndex(handle); }

    /**
     * 加载 LRC 格式的歌词内容。
     *
     * @param lrcContent LRC 格式的歌词文本
     */
    public void loadLyrics(String lrcContent) { nativeLoadLyrics(handle, lrcContent); }

    /**
     * 获取当前播放时间对应的歌词行文本。
     *
     * @return 当前歌词行，无歌词时返回空字符串
     */
    public String getCurrentLyric() { return nativeGetCurrentLyric(handle); }

    /**
     * 设置循环模式。
     *
     * @param mode 循环模式（0=不循环, 1=单曲循环, 2=列表循环）
     */
    public void setRepeatMode(int mode) { nativeSetRepeatMode(handle, mode); }

    /**
     * 启用或禁用随机播放。
     *
     * @param enabled true 启用随机播放，false 禁用
     */
    public void setShuffle(boolean enabled) { nativeSetShuffle(handle, enabled); }

    // ---- 事件轮询 ----

    /**
     * 事件监听器接口。
     *
     * <p>原生层不直接回调 Java 方法（避免 JNI 回调的复杂性），
     * 而是通过轮询机制将事件传递到 Java 层。
     * 实现此接口可接收播放器的各类事件通知。</p>
     */
    public interface EventListener {
        /**
         * 播放状态变更回调。
         *
         * @param state 新的播放状态码，参见 STATE_* 常量
         */
        void onStateChanged(int state);

        /**
         * 曲目播放结束回调。
         * 可在此处理自动播放下一首等逻辑。
         */
        void onTrackEnded();

        /**
         * 播放进度更新回调。
         *
         * @param positionMs 当前播放位置（毫秒）
         * @param durationMs 媒体总时长（毫秒）
         */
        void onProgress(long positionMs, long durationMs);

        /**
         * 播放错误回调。
         *
         * @param message 错误描述信息
         */
        void onError(String message);

        /**
         * 缓冲状态变更回调。
         *
         * @param buffering true 表示开始缓冲，false 表示缓冲结束
         */
        void onBuffering(boolean buffering);
    }

    private EventListener listener;

    /**
     * 设置事件监听器。
     * 设置非 null 监听器时自动启动轮询线程。
     *
     * @param listener 事件监听器实现
     */
    public void setEventListener(EventListener listener) {
        this.listener = listener;
        if (listener != null) {
            startPollingThread();
        }
    }

    /**
     * 启动事件轮询线程。
     *
     * <p>工作机制：以 50ms 间隔不断调用 nativePollEvent() 从原生层拉取事件，
     * 根据事件类型分发到对应的监听器方法。设为守护线程，不阻止 JVM 退出。</p>
     *
     * <p>选择轮询而非回调的原因：JNI 从原生线程回调 Java 需要额外管理
     * JNIEnv 和线程附着（AttachCurrentThread），轮询模式更简单可靠。</p>
     */
    private void startPollingThread() {
        Thread thread = new Thread(() -> {
            while (running && handle != 0) {
                int event = nativePollEvent(handle);
                if (event != EVENT_NONE && listener != null) {
                    switch (event) {
                        case EVENT_STATE_CHANGED -> listener.onStateChanged(nativeGetState(handle));
                        case EVENT_TRACK_ENDED -> listener.onTrackEnded();
                        case EVENT_PROGRESS_UPDATE -> listener.onProgress(
                            nativeGetPosition(handle), nativeGetDuration(handle));
                        case EVENT_ERROR -> listener.onError("播放错误");
                        case EVENT_BUFFERING -> listener.onBuffering(true);
                    }
                }
                try { Thread.sleep(50); } catch (InterruptedException e) { break; }
            }
        });
        // 守护线程：JVM 退出时不需要等待此线程结束
        thread.setDaemon(true);
        thread.start();
    }

    // ---- 交互式 CLI ----

    /** 终端原始模式已激活标记 */
    private static boolean rawModeActive = false;

    /**
     * 交互式 CLI 入口。
     *
     * <p>功能与 Zig CLI（main.zig）对齐：
     * <ul>
     *   <li>命令行参数：{@code play <URL或路径> [--lyrics <LRC路径或URL>]}</li>
     *   <li>实时显示：进度条 + 播放状态 + 时间 + 音量 + 歌词</li>
     *   <li>键盘控制：空格暂停/播放、q 退出、←→ 快退/快进 5 秒、↑↓ 音量增减 10%</li>
     * </ul>
     * </p>
     *
     * @param args 命令行参数
     * @author 真心
     * @since 2026-04-22 00:00
     */
    public static void main(String[] args) {
        // ---- 参数解析 ----
        if (args.length == 0) {
            printUsage();
            return;
        }

        if (args[0].equals("--help") || args[0].equals("-h")) {
            printHelp();
            return;
        }

        if (!args[0].equals("play")) {
            System.out.println("未知命令: " + args[0]);
            return;
        }

        if (args.length < 2) {
            System.out.println("错误: play 命令需要一个 URL 或文件路径");
            return;
        }

        String source = args[1];
        String lyricsPath = null;
        int volumePct = 20;

        for (int i = 2; i < args.length; i++) {
            if ("--lyrics".equals(args[i]) && i + 1 < args.length) {
                lyricsPath = args[++i];
            } else if ("--volume".equals(args[i]) && i + 1 < args.length) {
                volumePct = Integer.parseInt(args[++i]);
                volumePct = Math.max(0, Math.min(100, volumePct));
            }
        }

        // ---- 初始化播放器 ----
        ZMusicPlayer player = new ZMusicPlayer();
        player.setVolume(volumePct / 100f);
        try {
            // 加载歌词（如果指定）
            boolean hasLyrics = false;
            if (lyricsPath != null) {
                String lrcContent = loadTextResource(lyricsPath);
                if (lrcContent != null) {
                    player.loadLyrics(lrcContent);
                    hasLyrics = true;
                } else {
                    System.out.println("无法加载歌词: " + lyricsPath);
                    return;
                }
            }

            System.out.println("正在播放: " + source);
            if (hasLyrics) {
                System.out.println("歌词已加载: " + lyricsPath);
            }

            int ret = player.play(source);
            if (ret != 0) {
                System.out.println("播放失败 (错误码: " + ret + ")");
                return;
            }

            // ---- 进入终端原始模式 ----
            enableRawMode();
            boolean displayStarted = false;

            // ---- 主显示循环 ----
            // 固定 3 行显示区，原地刷新：
            //   第 1 行：进度条
            //   第 2 行：播放状态 + 时间 + 音量 + 歌词
            //   第 3 行：控制提示
            while (true) {
                int state = player.getState();
                if (state != STATE_PLAYING && state != STATE_PAUSED) break;

                // 键盘控制
                int key = readKey();
                if (key != 0) {
                    switch (key) {
                        case ' ' -> {
                            if (state == STATE_PLAYING) player.pause();
                            else if (state == STATE_PAUSED) player.resume();
                        }
                        case 'q', 'Q' -> {
                            player.stop();
                            continue;
                        }
                        case 27 -> {
                            // ANSI 转义序列：方向键 ESC [ A/B/C/D
                            int c1 = readKey();
                            int c2 = readKey();
                            if (c1 == '[') {
                                switch (c2) {
                                    case 'D' -> { // 左箭头：快退 5 秒
                                        long pos = player.getPosition();
                                        player.seek(Math.max(0, pos - 5000));
                                    }
                                    case 'C' -> { // 右箭头：快进 5 秒
                                        long pos = player.getPosition();
                                        long dur = player.getDuration();
                                        if (pos + 5000 < dur) player.seek(pos + 5000);
                                    }
                                    case 'A' -> // 上箭头：音量 +10%
                                        player.setVolume(Math.min(1.0f, player.getVolume() + 0.1f));
                                    case 'B' -> // 下箭头：音量 -10%
                                        player.setVolume(Math.max(0.0f, player.getVolume() - 0.1f));
                                }
                            }
                        }
                    }
                }

                // 检测播放结束
                if (state == STATE_PLAYING) {
                    long pos = player.getPosition();
                    long dur = player.getDuration();
                    // 时长有效且位置接近末尾，视为播放结束
                    if (dur > 0 && pos > 0 && pos >= dur - 500) break;
                }

                // ---- 重绘 3 行显示区 ----
                long position = player.getPosition();
                long duration = player.getDuration();

                // 第 1 行：进度条
                float pct = duration > 0 ? (float) position / duration : 0f;
                int barWidth = 40;
                int filled = (int) (pct * barWidth);
                StringBuilder bar = new StringBuilder("\r\u001B[2K进度：[");
                for (int j = 0; j < barWidth; j++) {
                    bar.append(j < filled ? '█' : '░');
                }
                bar.append(']');
                System.out.println(bar);

                // 第 2 行：播放状态 + 时间 + 音量 + 歌词
                String stateIcon = switch (player.getState()) {
                    case STATE_PLAYING -> "▶";
                    case STATE_PAUSED -> "⏸";
                    default -> "■";
                };
                long posMin = position / 60000;
                long posSec = (position % 60000) / 1000;
                long durMin = duration / 60000;
                long durSec = (duration % 60000) / 1000;
                int volPct = (int) (player.getVolume() * 100);

                System.out.printf("\r\u001B[2K%s %02d:%02d/%02d:%02d", stateIcon, posMin, posSec, durMin, durSec);
                if (volPct != 100) System.out.printf(" vol:%02d%%", volPct);

                String lyric = player.getCurrentLyric();
                if (lyric != null && !lyric.isEmpty()) {
                    System.out.print("  " + lyric);
                }
                System.out.println();

                // 第 3 行：控制提示
                System.out.print("\r\u001B[2KSpace:暂停/播放  q:退出  ←→:快退/快进  ↑↓:音量\n");

                // 光标上移 3 行，回到显示区起点
                System.out.print("\u001B[3A");
                System.out.flush();

                displayStarted = true;
                Thread.sleep(200);
            }

            if (displayStarted) System.out.println();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } finally {
            disableRawMode();
            player.destroy();
        }
    }

    // ---- 终端控制 ----

    /**
     * 启用终端原始模式：关闭行缓冲和回显。
     * 使用 {@code stty} 命令修改终端属性，仅支持 Unix/Linux/macOS。
     */
    private static void enableRawMode() {
        String os = System.getProperty("os.name", "").toLowerCase();
        if (os.contains("win")) return; // Windows 暂不支持原始模式
        try {
            Runtime.getRuntime().exec(new String[]{"/bin/sh", "-c",
                "stty -echo -icanon min 0 time 0 < /dev/tty"}).waitFor();
            rawModeActive = true;
        } catch (Exception ignored) {}
    }

    /**
     * 恢复终端为正常模式。
     */
    private static void disableRawMode() {
        if (!rawModeActive) return;
        try {
            Runtime.getRuntime().exec(new String[]{"/bin/sh", "-c",
                "stty echo icanon < /dev/tty"}).waitFor();
            rawModeActive = false;
        } catch (Exception ignored) {}
    }

    /**
     * 从标准输入读取一个按键（非阻塞）。
     *
     * @return 按键的 ASCII 码，无输入时返回 0
     */
    private static int readKey() {
        try {
            if (System.in.available() > 0) return System.in.read();
        } catch (Exception ignored) {}
        return 0;
    }

    // ---- 资源加载 ----

    /**
     * 加载文本资源，支持本地文件和 HTTP(S) URL。
     *
     * <p>本地文件使用 {@link java.io.File} 读取，
     * HTTP URL 使用 {@link java.net.HttpURLConnection} 下载。</p>
     *
     * @param path 本地文件路径或 HTTP(S) URL
     * @return 文本内容，加载失败时返回 null
     * @author 真心
     * @since 2026-04-22 00:00
     */
    private static String loadTextResource(String path) {
        try {
            byte[] bytes;
            String detectedCharset = null;

            if (path.startsWith("http://") || path.startsWith("https://")) {
                // HTTP(S) URL：下载歌词内容
                var url = java.net.URI.create(path).toURL();
                var conn = (java.net.HttpURLConnection) url.openConnection();
                conn.setConnectTimeout(10000);
                conn.setReadTimeout(10000);
                conn.setRequestMethod("GET");

                // 从 Content-Type 头提取 charset
                String contentType = conn.getContentType();
                if (contentType != null) {
                    for (String part : contentType.split(";")) {
                        String trimmed = part.trim().toLowerCase();
                        if (trimmed.startsWith("charset=")) {
                            detectedCharset = trimmed.substring(8).trim();
                            break;
                        }
                    }
                }

                try (var is = conn.getInputStream()) {
                    bytes = is.readAllBytes();
                }
            } else {
                // 本地文件
                bytes = java.nio.file.Files.readAllBytes(java.nio.file.Path.of(path));
            }

            // 编码检测：有 charset 用 charset，否则尝试 UTF-8，失败则回退 GBK
            if (detectedCharset != null) {
                return new String(bytes, detectedCharset);
            }
            // 跳过 BOM（如有）
            int start = (bytes.length >= 3 && bytes[0] == (byte) 0xEF
                    && bytes[1] == (byte) 0xBB && bytes[2] == (byte) 0xBF) ? 3 : 0;
            String candidate = new String(bytes, start, bytes.length - start,
                    java.nio.charset.StandardCharsets.UTF_8);
            // UTF-8 替换字符检测：如果包含替换字符说明不是有效 UTF-8
            if (candidate.indexOf('\uFFFD') < 0) return candidate;
            return new String(bytes, java.nio.charset.Charset.forName("GBK"));
        } catch (Exception e) {
            return null;
        }
    }

    // ---- 帮助信息 ----

    /**
     * 打印用法提示。
     */
    private static void printUsage() {
        System.out.println("用法: java me.zhenxin.zmusic.ZMusicPlayer <命令> [参数...]");
        System.out.println("命令:");
        System.out.println("  play <URL或路径>  播放 URL 或本地音频文件");
        System.out.println("  --help            显示帮助信息");
    }

    /**
     * 打印详细帮助信息。
     */
    private static void printHelp() {
        System.out.println("ZMusic Player - 网络音频播放器");
        System.out.println();
        System.out.println("用法: java me.zhenxin.zmusic.ZMusicPlayer play <URL或路径> [--lyrics <LRC路径>] [--volume <0-100>]");
        System.out.println();
        System.out.println("选项:");
        System.out.println("  --lyrics <路径>    加载 LRC 格式歌词文件（支持本地路径和 HTTP URL）");
        System.out.println("  --volume <0-100>   设置初始音量百分比，默认 20");
        System.out.println();
        System.out.println("播放控制:");
        System.out.println("  Space   播放 / 暂停");
        System.out.println("  q       停止并退出");
        System.out.println("  ←/→     快退/快进 5 秒");
        System.out.println("  ↑/↓     音量增减 10%");
    }

    /**
     * 将播放状态码转换为可读字符串。
     *
     * @param state 状态码，参见 STATE_* 常量
     * @return 状态对应的英文名称
     */
    private static String stateToString(int state) {
        return switch (state) {
            case STATE_STOPPED -> "STOPPED";
            case STATE_LOADING -> "LOADING";
            case STATE_PLAYING -> "PLAYING";
            case STATE_PAUSED -> "PAUSED";
            case STATE_ERROR -> "ERROR";
            default -> "UNKNOWN(" + state + ")";
        };
    }

}
