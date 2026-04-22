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
        System.loadLibrary("zmusic-player");
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

    // ---- 演示 ----

    /**
     * 演示程序入口。
     *
     * <p>演示流程：初始化 → 设置事件监听 → 播放 → 暂停 → 恢复 → 销毁。
     * 通过命令行参数传入音频 URL 或本地路径。</p>
     *
     * @param args 命令行参数，第一个参数为音频 URL 或本地文件路径
     */
    public static void main(String[] args) {
        ZMusicPlayer player = new ZMusicPlayer();
        try {
            // 设置事件监听器，打印各类事件信息
            player.setEventListener(new EventListener() {
                @Override public void onStateChanged(int state) {
                    System.out.println("[状态] " + stateToString(state));
                }
                @Override public void onTrackEnded() {
                    System.out.println("[事件] 播放结束");
                }
                @Override public void onProgress(long pos, long dur) {
                    System.out.printf("[进度] %d/%d ms%n", pos, dur);
                }
                @Override public void onError(String msg) {
                    System.out.println("[错误] " + msg);
                }
                @Override public void onBuffering(boolean buf) {
                    System.out.println("[缓冲] " + buf);
                }
            });

            if (args.length > 0) {
                // 开始播放命令行指定的音频
                System.out.println("正在播放: " + args[0]);
                player.play(args[0]);

                // 播放 10 秒后暂停
                Thread.sleep(10000);
                System.out.println("暂停中...");
                player.pause();

                // 暂停 2 秒后恢复播放
                Thread.sleep(2000);
                System.out.println("恢复播放...");
                player.resume();

                // 继续播放 5 秒后结束
                Thread.sleep(5000);
            } else {
                System.out.println("用法: java me.zhenxin.zmusic.ZMusicPlayer <URL或路径>");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } finally {
            // 无论是否异常，确保销毁原生资源
            player.destroy();
        }
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

    /**
     * 终结器：作为资源释放的最后保障。
     * 正常使用时应显式调用 destroy()，此方法仅防止资源泄漏。
     */
    @Override
    protected void finalize() throws Throwable {
        destroy();
        super.finalize();
    }
}
