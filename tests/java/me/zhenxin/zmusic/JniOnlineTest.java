package me.zhenxin.zmusic;

public final class JniOnlineTest {
    private static final String TEST_MP3 =
        "https://cdn.zhenxin.me/%E6%88%91%E7%9A%84%E6%82%B2%E4%BC%A4%E6%98%AF%E6%B0%B4%E5%81%9A%E7%9A%84.mp3";

    public static void main(String[] args) throws Exception {
        ZMusicPlayer player = new ZMusicPlayer();
        try {
            require(player.play(TEST_MP3) == 0, "在线 MP3 播放失败");
            require(player.getState() == 2, "播放后状态必须为 playing");
            require(player.getDuration() > 10_000, "在线 MP3 时长无效");

            Thread.sleep(1200);
            require(player.getPosition() > 500, "播放进度未推进");

            require(player.pause() == 0, "暂停失败");
            long pausedAt = player.getPosition();
            Thread.sleep(300);
            require(Math.abs(player.getPosition() - pausedAt) < 100, "暂停后进度仍在推进");

            require(player.resume() == 0, "恢复失败");
            require(player.seek(5000) == 0, "跳转失败");
            Thread.sleep(200);
            require(player.getPosition() >= 4900, "跳转位置不正确");

            require(player.stop() == 0, "停止失败");
            require(player.getState() == 0, "停止后状态必须为 stopped");
        } finally {
            player.destroy();
        }
        System.out.println("JNI_ONLINE_OK");
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
