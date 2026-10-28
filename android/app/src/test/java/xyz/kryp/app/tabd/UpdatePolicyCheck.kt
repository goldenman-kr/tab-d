package xyz.kryp.app.tabd

internal fun checkAndroidUpdatePolicy(): Int {
    var count = 0
    fun expect(value: Boolean) { check(value); count++ }
    expect(AndroidUpdatePolicy.newer("0.6.10", "0.6.9"))
    expect(AndroidUpdatePolicy.newer("1.0.0", "0.99.99"))
    expect(!AndroidUpdatePolicy.newer("0.6.5", "0.6.5"))
    expect(!AndroidUpdatePolicy.newer("0.6.4", "0.6.5"))
    for (value in listOf("v0.6.6", "0.6", "0.6.6-beta", "-1.0.0", "1.0.999999999999999999999", " 1.0.0"))
        expect(!AndroidUpdatePolicy.newer(value, "0.6.5"))
    expect(AndroidUpdatePolicy.assetVersion("Mr-Tab-D-0.6.5-Android.apk") == "0.6.5")
    for (value in listOf("Mr-Tab-D-0.6.5-macOS-arm64.dmg", "Mr-Tab-D-0.6.5-Android.apk.exe", "../Mr-Tab-D-0.6.5-Android.apk"))
        expect(AndroidUpdatePolicy.assetVersion(value) == null)
    expect(AndroidUpdatePolicy.releaseAsset("https://github.com/goldenman-kr/tab-d/releases/download/v0.6.5/asset.apk"))
    for (value in listOf("http://github.com/goldenman-kr/tab-d/releases/download/v1/a", "https://github.com.evil.example/goldenman-kr/tab-d/releases/download/v1/a", "https://github.com/another/tab-d/releases/download/v1/a", "https://github.com/goldenman-kr/tab-d/releases/download/../bad", "https://user@github.com/goldenman-kr/tab-d/releases/download/v1/a", "https://github.com:444/goldenman-kr/tab-d/releases/download/v1/a", "https://github.com/goldenman-kr/tab-d/releases/download/v1/a?redirect=evil"))
        expect(!AndroidUpdatePolicy.releaseAsset(value))
    val sha = "ab".repeat(32)
    val name = "Mr-Tab-D-0.6.5-Android.apk"
    expect(AndroidUpdatePolicy.checksum("${sha.uppercase()}  $name\n", name) == sha)
    expect(AndroidUpdatePolicy.checksum("$sha  different.apk\n", name) == null)
    expect(AndroidUpdatePolicy.checksum("$sha  $name\n$sha  $name\n", name) == null)
    expect(AndroidUpdatePolicy.checksum("invalid  $name\n", name) == null)
    expect(AndroidUpdatePolicy.checksum("", name) == null)
    expect(AndroidUpdatePolicy.sameSigners(setOf("trusted"), setOf("trusted")))
    expect(!AndroidUpdatePolicy.sameSigners(setOf("trusted"), setOf("different")))
    expect(!AndroidUpdatePolicy.sameSigners(emptySet(), emptySet()))
    expect(!AndroidUpdatePolicy.sameSigners(setOf("trusted"), setOf("trusted", "different")))
    return count
}
