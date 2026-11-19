// Fill these in before deploying. Empty links hide their button.
window.SITE = {
  playStore: '',
  // Direct APK download, served from this site (not committed to git; copy it
  // to website/download/ on the server). Remove once the Play Store link is live.
  androidApk: '/download/securelyhello.apk',
  // Smaller per-CPU APKs from tools/release_apk.py --split (empty hides them):
  //   '/download/securelyhello-arm64-v8a.apk', '/download/securelyhello-armeabi-v7a.apk'
  androidApkArm64: '',
  androidApkArm32: '',
  // SHA-256 of the APK signing certificate, shown next to the APK link.
  apkCertSha256: '78:8E:E6:48:86:1E:AF:80:39:49:6C:23:42:64:79:39:93:04:D5:F9:A3:C6:34:63:79:5A:4A:C2:5E:11:B6:E1', // https://play.google.com/store/apps/details?id=securelyhello.thenn.in
  appStore: '', // https://apps.apple.com/app/id…
  desktop: '', // releases page with Windows / macOS / Linux builds
  source: 'https://github.com/securelyhello/TheSecurelyHelloProject',
  contact: 'hello@thenn.in',
};
