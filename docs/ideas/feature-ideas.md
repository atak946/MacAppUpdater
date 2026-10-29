# MacAppUpdater — Özellik Fikirleri (Ekim 2026)

> Kapsam: Halihazırda yapılmış/yapılmakta olan özellikler (Sparkle/Homebrew/GitHub/MAS kaynakları, imza + Team ID doğrulama, pkg helper, rollback, politika, uninstaller, insights, menü bar, self-update vb.) **tekrar önerilmemiştir**.
> Referans modüller: `UpdateSource` / `SourceMatching` (`Sources/AppUpdaterCore/Sources`), `UpdateChecker`, `UpdatePolicy` / `UpdatePoliciesStoring`, `ExclusionRules`, `UpdateScheduler`, `UpdateNotifier`, `CompatibilityAnalyzer`, `AppWarning`, `TeamIdentifierStore`, `CodeSignatureVerifier`, `DownloadVerifier`, `AppInstaller`, `HomebrewCLI`, `AppEnvironment.swift` (composition root).

---

## 1. Rekabet ortamı — kısa özet

- **MacUpdater kapandı (1 Ocak 2026).** CoreCode sürdürülebilir fiyat modeli bulamadığını, pazarlama yapmadığını, kurumsal pazara girmediğini ve etik gerekçeyle aboneliği reddettiğini söyledi; 3.5 "offline" sürüm artık online kontrol yapmıyor. Kod/teknoloji satışa çıkarıldı. → [TidBITS](https://tidbits.com/2026/01/09/macupdater-shuts-down-leaving-users-searching-for-alternatives/), [AlternativeTo haberi](https://alternativeto.net/news/2025/5/macupdater-to-be-discontinued-in-january-2026-code-and-technology-up-for-sale)
- **Kullanıcıların özlediği şey kapsam (coverage).** MacUpdater'ın elle bakılan devasa veritabanı, tek pencereden toplu güncelleme, birden çok Mac'i merkezi yönetme ve false-positive'lere hızlı yanıt. Alternatifler "MacUpdater'ın bulduğunun yarısını" buluyor. → [TidBITS forumu](https://talk.tidbits.com/t/macupdater-shuts-down-leaving-users-searching-for-alternatives/32642), [MPU forumu](https://talk.macpowerusers.com/t/macupdater-alternatives/43783), [MacRumors](https://forums.macrumors.com/threads/rip-macupdater.2456354/page-3), [Sir Apfelot](https://www.sir-apfelot.de/beste-macupdater-alternative-2026-68588/)
- **Latest** (açık kaynak): temiz arayüz, ama esasen Sparkle + MAS; "limited support" uygulamaları uygulama içinden güncelleyemiyor, geliştirme yavaş. **Updatest**: en yakın alternatif ama Electron uygulamaları elle, Adobe/Epson/Xcode eksik. **Floodtide**: sadece Sparkle + Homebrew. **CleanMyMac Updater**: pahalı, testte uygulamaların ~%4'ünü buldu. → [Latest GitHub](https://github.com/mangerlahn/Latest), [TidBITS](https://tidbits.com/2026/01/09/macupdater-shuts-down-leaving-users-searching-for-alternatives/)
- **Homebrew / `brew bundle`**: güçlü ama sadece brew ile kurulanları yönetir; elle kurulan uygulamaları taramaz. `Brewfile` "yeni Mac kurulumu" için fiili standart. **Applite**: Homebrew cask GUI. → [Brew Bundle docs](https://docs.brew.sh/Brew-Bundle-and-Brewfile)
- **Topgrade**: tek komutla brew/mas/npm/pip/... güncellemesi; kullanıcılar açıkça "Topgrade GUI" istiyor. → [topgrade-rs/topgrade](https://github.com/topgrade-rs/topgrade), [MacRumors](https://forums.macrumors.com/threads/rip-macupdater.2456354/page-3)
- **mas-cli**: macOS 15.4'te private CommerceKit kırıldı, Spotlight metadata'ya geçildi; macOS 26.1/15.7.2/14.8.2 sonrası install/upgrade **root istiyor**. MAS'ı otomatik güncellemek kırılgan. → [mas releases](https://github.com/mas-cli/mas/releases)
- **Kurumsal (Jamf App Installers, Kandji Auto Apps, Installomator, Munki)**: kurumsal yama yönetimi küratörlü katalog + "update only" modu + raporlama üzerine kurulu. Installomator, Jamf kataloğunda olmayan uygulamalar için "label" tabanlı script; her label'da `expectedTeamID` var. → [Kandji Update Only](https://blog.kandji.io/update-only-mode-auto-apps-patch-management-mac-software), [Jamf Community – Installomator](https://community.jamf.com/t5/tech-thoughts/revolutionizing-patch-management-with-installomator/ba-p/350112), [App Auto-Patch](https://community.jamf.com/t5/jamf-pro/app-auto-patch-2-9-3-automate-your-mac-s-application-management/m-p/311119), [Installomator](https://github.com/Installomator/Installomator), [Munki](https://github.com/munki/munki)
- **Setapp / AppCleaner**: Setapp kendi uygulamalarını kendi güncelliyor (bizim dokunmamamız gerekir); AppCleaner ücretsiz, tek amaçlı kaldırıcı — bizim uninstaller zaten bu alanı kapsıyor. → [Setapp](https://setapp.com), [AppCleaner](https://freemacsoft.net/appcleaner/)

**Çıkarım:** Pazardaki boşluk "kapsam + güven + kurumsal hafif katman". Kazanan ürün, en çok uygulamayı **güvenli** biçimde güncelleyen, neyi bulamadığını dürüstçe söyleyen ve IT için yönetilebilir olan olacak.

---

## 2. Özellik fikirleri

Efor: **S** ≤ 2 gün, **M** ≈ 1 hafta, **L** > 2 hafta (tek ajan/geliştirici).

### A. Veri kaynakları (kapsamı büyütmek — en büyük değer)

**A1. Electron/Squirrel kaynağı (`latest-mac.yml`)** — Efor: M
- **Ne:** electron-builder ile paketlenen uygulamalar (Slack, Discord, Obsidian, Notion, VS Code türevleri…) `app-update.yml` dosyasını bundle içine (`Contents/Resources/app-update.yml`) koyar; bu dosya feed sağlayıcısını (GitHub, S3, generic URL) söyler. Feed'deki `latest-mac.yml` sürüm, dosya URL'si ve `sha512` içerir.
- **Neden:** Updatest'in bile elle bıraktığı en büyük kategori Electron uygulamaları.
- **Nasıl:** Yeni `ElectronUpdateSource: SourceMatching` (`Sources/AppUpdaterCore/Sources/ElectronUpdateSource.swift`) + `ElectronFeedParser` (YAML alt kümesi, bağımlılıksız elle parse). `UpdateSourceKind`'a `.electron` ekle. `DownloadVerifier`'a SHA-512 desteği. Kurulum: zip → mevcut `AppInstaller`; Team ID kontrolü aynen uygulanır.
- **Risk:** Squirrel.Mac kullanan (electron-builder olmayan) uygulamalarda feed dinamik/kimlik doğrulamalı olabilir → sadece `app-update.yml` bulunanları destekle. `UpdateSourceKind` enum'u değişeceği için Models.swift'e dokunur — tek ajan sahiplensin.

**A2. Bildirimsel vendor feed'leri (`VendorFeedSource`)** — Efor: M
- **Ne:** Belgelenmiş, herkese açık JSON/XML API'leri için veri-tabanlı tanımlar: JetBrains (`data.services.jetbrains.com/products/releases`), Mozilla `product-details` JSON, Microsoft AutoUpdate CDN XML'leri, Google Chrome versionhistory API.
- **Neden:** Kendi updater'ı olan büyük uygulamalar (Chrome, Firefox, Office, JetBrains) şu an "manuel" kalıyor.
- **Nasıl:** `VendorFeedDefinition` (bundleId, url, JSONPath benzeri basit anahtar yolu, `expectedTeamID`, `downloadURLTemplate`) içeren paketle gelen `vendor-feeds.json`; tek generic `VendorFeedSource`. Yeni vendor eklemek kod değil veri değişikliği.
- **Risk:** Yalnızca resmi/belgelenmiş endpoint'ler; HTML scraping **yok** (bkz. §3). Office gibi uygulamalar kendi updater'ını tercih eder → varsayılan "uyar + vendor updater'ı aç".

**A3. Installomator label'larından Team ID / kaynak meta verisi** — Efor: M
- **Ne:** Installomator'ın ~1000 label'ındaki `expectedTeamID` ve `name`/`type` alanlarını build zamanında çıkarıp statik bir tabloya dönüştür.
- **Neden:** İlk kurulumda `TeamIdentifierStore` boş; bilinen Team ID ile çapraz kontrol, ilk güncellemede bile imza değişikliği tespitini mümkün kılar.
- **Nasıl:** `scripts/import-installomator-teamids.sh` → `Resources/known-team-ids.json`; `TeamIdentifierStore`'a salt-okunur "seed" katmanı.
- **Risk:** Label'lar shell script'tir — **çalıştırılmamalı**, sadece regex ile statik alanlar okunmalı. Lisans Apache-2.0 → NOTICE dosyasına atıf.

**A4. Kapsam paneli + "eksik uygulamayı bildir"** — Efor: S
- **Ne:** "Kaynağı bilinmeyen uygulamalar" listesi; her biri için "GitHub repo eşle", "Homebrew'da ara", "Bildir" butonları. Bildir, önceden doldurulmuş GitHub issue URL'si açar (bundleId, sürüm, `SUFeedURL` var mı, imza Team ID).
- **Neden:** Kullanıcılar hangi uygulamaların takip edilmediğini bilmiyor; MacUpdater'ın gücü false-positive/eksik raporlarına hızlı yanıttı. Hangi kaynağı ekleyeceğimize veriyle karar veririz.
- **Nasıl:** `UpdateChecker` sonuçlarından "hiçbir kaynak `canHandle` demedi" kümesi; yeni `UI/Coverage/CoverageView.swift`. Telemetri yok, kullanıcı tıklamasıyla tarayıcıda açılır.
- **Risk:** Issue'da kişisel veri olmamalı (yol, kullanıcı adı). Düşük risk.

**A5. Setapp / kendi kendini güncelleyen uygulama tespiti** — Efor: S
- **Ne:** `/Applications/Setapp/` altındaki ve Setapp imzalı uygulamaları, ayrıca bilinen "kendi updater'ı zorunlu" uygulamaları (Adobe CC, Microsoft, Chrome Keystone) işaretle ve doğru araca yönlendir.
- **Neden:** Setapp uygulamasını Sparkle feed'inden güncellemek Setapp lisanslamasını bozabilir; yanlış "güncelleme var" gürültüsü azalır.
- **Nasıl:** `InstallMethod` / `AppWarning`'e yeni vaka (`.managedBySetapp`, `.vendorUpdaterRequired`); `ExclusionRules`'a otomatik kural.
- **Risk:** Yok denecek kadar az.

**A6. Topluluk manifest deposu (imzalı)** — Efor: L
- **Ne:** Ayrı bir GitHub reposunda topluluk katkılı JSON manifest (bundleId → kaynak tanımı, A2 formatında). Uygulama periyodik olarak imzalı bundle'ı çeker.
- **Neden:** MacUpdater'ın veritabanı avantajını sürdürülebilir şekilde (topluluk + PR review) yeniden üretmek.
- **Nasıl:** A2'nin `VendorFeedDefinition` formatını yeniden kullan; manifest'i EdDSA ile imzala (Sparkle anahtar altyapısı zaten var), `ManifestUpdater` doğrulamadan yüklemesin.
- **Risk:** Tedarik zinciri saldırısı yüzeyi: kötü niyetli PR ile download URL değiştirme. Zorunlu: imzalı manifest + `expectedTeamID` alanı + Team ID eşleşmesi (mevcut kontrol) → manifest tek başına zararlı binary kurdurtamaz. Bakım yükü gerçek.

### B. Güvenlik

**B1. Notarization/Gatekeeper ön kontrolü** — Efor: S
- **Ne:** Kurulumdan önce yeni bundle'ı `spctl --assess --type execute` ve `stapler validate` ile değerlendir; notarize değilse kurma (veya açık onay iste).
- **Neden:** Team ID eşleşmesi gerekli ama yeterli değil; çalınmış/iptal edilmiş sertifika, notarize edilmemiş build'i yakalar.
- **Nasıl:** `CodeSignatureVerifier`'ın yanına `GatekeeperAssessor` (CommandRunner üzerinden); `AppInstaller` pipeline'ına bir adım.
- **Risk:** Eski/küçük geliştiricilerin bazı uygulamaları notarize değil → kullanıcı ayarı "notarize olmayanlara izin ver (uyar)".

**B2. "Soak period" — gecikmeli otomatik güncelleme** — Efor: S
- **Ne:** Otomatik kurulum için "sürüm yayımlandıktan N gün sonra kur" ayarı (global + uygulama başına). Kritik güvenlik güncellemeleri için istisna.
- **Neden:** Kurumsal araçların (Kandji/Jamf deferral) standardı; bozuk .0 sürümlerinden korur. Mevcut rollback'i tamamlar.
- **Nasıl:** `UpdatePolicy`'e `deferralDays: Int`; `AvailableUpdate.publishedAt` (appcast `pubDate`, GitHub `published_at`, cask API'de yoksa "ilk görülme tarihi"ni yerel kaydet). `UpdateScheduler` filtreler.
- **Risk:** Yayın tarihi bilinmeyen kaynaklarda "ilk görülme" kullanılmalı; bu dürüstçe UI'da belirtilmeli.

**B3. İndirme host'u değişim uyarısı** — Efor: S
- **Ne:** Bir uygulamanın indirme domain'i önceki güncellemelere göre değişirse (ör. `github.com` → `random-cdn.xyz`) uyar.
- **Neden:** Ele geçirilmiş appcast'lerin tipik işareti. Team ID kontrolü yakalar ama erken ve açıklayıcı uyarı güven verir.
- **Nasıl:** `TeamIdentifierStore` benzeri `DownloadHostStore`; `AppWarning.downloadHostChanged`.
- **Risk:** CDN geçişlerinde false-positive → bilgi seviyesi uyarı, engelleme değil.

**B4. Bilinen açık (CVE/KEV) farkındalığı** — Efor: L
- **Ne:** Kurulu sürüm, CISA KEV listesinde veya NVD'de bilinen exploit'li bir sürümse "güvenlik güncellemesi" etiketi + öncelik.
- **Neden:** MacUpdater kullanıcılarının vurguladığı "güvenlik yamalarını hızlı uygulama".
- **Nasıl:** bundleId → CPE eşleme tablosu (küçük, elle küratörlü: Chrome, Firefox, Zoom, Office, VLC…); CISA KEV JSON'u günlük çek. `AvailableUpdate`'e `isSecurityRelevant`.
- **Risk:** CPE eşlemesi kırılgan, false-positive/negative yüksek; NVD API rate limit. Sadece küratörlü küçük listeyle başla, "kesin" dil kullanma.

### C. Otomasyon

**C1. CLI: `appupdater` (JSON çıktılı)** — Efor: M
- **Ne:** `appupdater list|outdated|upgrade [--all|<bundleId>] --json`. Topgrade için custom step olarak kullanılabilir.
- **Neden:** Power user ve IT talebi; Topgrade kullanıcılarının istediği "tüm kaynaklar tek komutta".
- **Nasıl:** `Package.swift`'e yeni `executableTarget("appupdater-cli")`, sadece `AppUpdaterCore`'a bağımlı; `swift-argument-parser`. App bundle içine `Contents/Helpers/` ile gönder, "CLI'yı kur" ayarı `/usr/local/bin` symlink.
- **Risk:** App Management izni (TCC) CLI'nın çalıştığı terminal uygulamasına atanır → kurulum adımları için uygulama içi XPC'ye delege etmek daha temiz (L'ye kayabilir). İlk sürüm: `list/outdated` salt-okunur.

**C2. Shortcuts / App Intents** — Efor: M
- **Ne:** "Güncellemeleri kontrol et", "Tümünü güncelle", "Bekleyen güncelleme sayısı" intent'leri.
- **Neden:** Kullanıcılar kendi otomasyonlarını (Focus modu, saat, ağ) kurabilir; düşük maliyetle büyük esneklik.
- **Nasıl:** `Sources/AppUpdater/Intents/` altında `AppIntent` conformance'ları; `AppEnvironment`'tan servisleri al.
- **Risk:** SwiftPM executable'da App Intents metadata çıkarımı Xcode build sistemine bağlı — packaging script'inde doğrulanmalı.

**C3. Koşullu kurulum: sessiz saatler, güç, ağ** — Efor: S
- **Ne:** Otomatik kurulumları "AC güce bağlıyken", "pahalı/kısıtlı ağda değilken" (`NWPath.isExpensive/isConstrained`), "uygulama çalışmıyorken", "22:00–08:00 arası değil" koşullarına bağla.
- **Neden:** Hotspot'ta 1 GB Xcode indirmek veya sunum sırasında uygulamayı kapatmak kötü deneyim.
- **Nasıl:** `UpdatePolicy`'e `InstallConditions`; yeni `SystemConditionsProvider` protokolü (NWPathMonitor, IOPSCopyPowerSourcesInfo, `NSWorkspace.runningApplications`). `UpdateScheduler` kontrol eder.
- **Risk:** B2 ile aynı dosyaya (`UpdatePolicy.swift`) dokunur → aynı ajan yapsın.

**C4. Uygulama seti export/import ("yeni Mac kurulumu")** — Efor: M
- **Ne:** Kurulu uygulamaları kaynaklarıyla (cask token, GitHub repo, MAS id, Sparkle feed) `AppSet.json` olarak dışa aktar; başka Mac'te içe aktar → eksik olanları kur. İsteğe bağlı `Brewfile` export'u.
- **Neden:** `brew bundle` sadece brew uygulamalarını kapsıyor; elle kurulanlar kayboluyor.
- **Nasıl:** `Sources/AppUpdaterCore/AppSet/` (yeni modül): `AppSetExporter`, `AppSetImporter`; kurulum için mevcut download/verify/install hattı. Ayarlar/exclusion'lar da dahil edilebilir.
- **Risk:** Lisanslı uygulamalar (kurulum ≠ lisans) — UI'da açıkça belirt. MAS için sadece store sayfasını aç.

### D. Kurumsal / IT

**D1. Managed preferences (MDM configuration profile)** — Efor: S/M
- **Ne:** IT, `.mobileconfig` ile politika, exclusion, soak period, otomatik kurulum, "kullanıcı değiştiremez" ayarlarını zorlayabilsin.
- **Neden:** MacUpdater'ın kendi itirafı: kurumsal pazara girmemek ölümcül oldu. MDM uyumu kurumsal benimsemenin giriş bileti.
- **Nasıl:** `ManagedPreferencesReader` (`CFPreferencesAppValueIsForced`) → `UpdatePoliciesStoring` / `ExclusionRulesStoring` üzerinde salt-okunur "forced" katmanı; UI'da kilit simgesi. Örnek profil `docs/mdm/` altında.
- **Risk:** Düşük; testte managed domain simülasyonu için protokol soyutlaması şart.

**D2. Envanter/uyumluluk raporu (export + webhook)** — Efor: M
- **Ne:** Uygulama envanteri, güncel olmayanlar, uyarılar (`AppWarning`) için CSV/JSON export; isteğe bağlı periyodik HTTPS webhook (IT dashboard, Slack).
- **Neden:** "Birden çok Mac'i merkezden yönetme" MacUpdater kullanıcılarının özlediği bir özellik; tam fleet yönetimi yerine hafif köprü.
- **Nasıl:** `InventoryReport` modeli (Codable) + `ReportExporter`; webhook URL'si D1 ile yönetilebilir.
- **Risk:** Gizlilik — varsayılan kapalı, açık onay, gönderilen alanların önizlemesi. Webhook token'ı Keychain'de.

**D3. Sürüm tavanı / pinleme** — Efor: S
- **Ne:** "Bu uygulamayı 5.x'te tut" (major tavanı) veya tam sürüme pinle.
- **Neden:** Ücretli major yükseltmeler, plugin uyumluluğu, kurumsal sertifikasyon.
- **Nasıl:** `ExclusionRules`'a `VersionCeiling` kuralı; `VersionComparator` ile `isNewer(candidate, than: ceiling)` filtresi `UpdateChecker`'da.
- **Risk:** Düşük.

### E. Kullanıcı deneyimi

**E1. Toplu güncelleme ön-izleme ve kuyruk** — Efor: M
- **Ne:** "Tümünü güncelle" öncesi özet: toplam indirme boyutu, kapatılacak çalışan uygulamalar, yönetici izni gerekenler (pkg), major sürüm atlayanlar. Eşzamanlılık limitli kuyruk, başarısızlıkta devam.
- **Neden:** MacUpdater'ın en sevilen özelliği tek pencereden toplu güncelleme; sürpriz uygulama kapanmaları güveni öldürür.
- **Nasıl:** `UpdateQueue` actor (`AppUpdaterCore/Install/`), `RunningAppTerminating` ile çalışan uygulama tespiti; UI'da sheet.
- **Risk:** `UpdatesViewModel` yoğun kullanılan dosya — çakışma riski, ajan sıralaması dikkatli yapılmalı.

**E2. Ücretli yükseltme / lisans uyarısı** — Efor: S
- **Ne:** Major sürüm atlamalarını ve Sparkle `sparkle:informationalUpdate` / `minimumAutoupdateVersion` işaretlerini "lisans gerekebilir" olarak göster; otomatik kurma.
- **Neden:** Ücretli upgrade'i kurup trial moduna düşmek yaygın şikâyet.
- **Nasıl:** `SparkleAppcastParser` bu alanları zaten görebilir; `AvailableUpdate`'e `isMajorUpgrade`, `requiresManualInstall` bayrağı; `AppWarning.possiblePaidUpgrade`.
- **Risk:** Sezgisel; dil "olabilir" olmalı.

**E3. Haftalık özet + cihaz üstü sürüm notu özeti** — Efor: M
- **Ne:** Haftada bir "12 uygulama güncellendi, 2 güvenlik düzeltmesi" bildirimi; macOS 26+ cihazlarda Foundation Models ile uzun sürüm notlarını 2-3 maddeye indir.
- **Neden:** Sürüm notlarını kimse okumuyor; önemli değişiklikler (veri formatı, ücretli) kaçıyor.
- **Nasıl:** Update history'den derleme `WeeklyDigestBuilder`; `ReleaseNotesLoading` çıktısını `ReleaseNotesSummarizer` protokolüne ver, `#available(macOS 26, *)` ile Foundation Models implementasyonu, aksi halde no-op.
- **Risk:** Hedef macOS 14 → özet özelliği sadece 26+'da. Yanlış özet riski → orijinal metne link her zaman görünür. Bulut LLM'e gönderme **yok** (gizlilik).

**E4. Masaüstü widget (WidgetKit)** — Efor: M
- **Ne:** Bekleyen güncelleme sayısı ve ilk 3 uygulama.
- **Nasıl:** Widget extension; App Group ile paylaşılan küçük JSON snapshot.
- **Risk:** SwiftPM ile widget extension paketlemek zor (Xcode projesi gerekebilir) → packaging script'ine maliyet. Düşük öncelik.

**E5. Menü bar hızlı arama / komut paleti** — Efor: S
- **Ne:** Menü bar panelinde arama alanı + klavye ile güncelle/yoksay/notları aç.
- **Nasıl:** `MenuBarView` içinde filtre; `.searchable` veya özel `TextField` + `onKeyPress`.
- **Risk:** Düşük.

### F. Topluluk

**F1. Topluluk "sorunlu sürüm" işaretleri** — Efor: L — **şimdilik önerilmez**
- **Ne:** Kullanıcıların "bu sürüm bozuk" oy vermesi, B2 soak period'u dinamikleştirmesi.
- **Neden önerilmez:** Backend, kimlik, abuse/brigading moderasyonu ve gizlilik yükü; MacUpdater'ı batıran bakım maliyetine benzer. A6 manifest deposunda `knownBadVersions` alanı (PR review ile) aynı faydanın %70'ini sunucusuz sağlar.

### G. Gelir modeli / dağıtım

**G1. Sürdürülebilirlik planı (MacUpdater dersi)** — Efor: S (karar) / M (lisans altyapısı)
- **Öneri:** Çekirdek (tarama + güncelleme) ücretsiz/açık kaynak; "Pro/Team" katmanı: D1 MDM, D2 raporlama, C1 CLI'nın yazma komutları, A6 öncelikli manifest. Bireyler için major-sürüm başına tek seferlik lisans, ekipler için yıllık koltuk lisansı. Ödeme: Paddle veya Lemon Squeezy (merchant of record → vergi yükü yok).
- **Neden:** MacUpdater'ın gerekçesi tam olarak bu: fiyat modeli yok + kurumsal yok. Kurumsal tarafta abonelik normaldir ve etik itiraz düşüktür.
- **Risk:** Lisans doğrulama kodunu `AppUpdaterCore`'dan ayrı tut; kırılırsa güncelleme fonksiyonu çalışmaya devam etmeli (güvenlik ürünü rehin alınmamalı).

**G2. Homebrew cask olarak dağıtım** — Efor: S
- **Ne:** `homebrew/cask`'e `macappupdater` cask'i; `auto_updates true` (Sparkle self-update var).
- **Neden:** Hedef kitlenin çoğu brew kullanıyor; keşfedilebilirlik.
- **Risk:** Cask kabul kriterleri (bilinirlik/star eşiği) — önce kendi tap'imiz.

---

## 3. Riskli / önermediğimiz fikirler

| Fikir | Neden önermiyoruz |
|---|---|
| Vendor sitelerini HTML scraping ile tarama | ToS ihlali riski, sayfa değişince sessizce kırılır, yanlış sürüm → yanlış "güncel" iddiası. Sadece resmi feed/API (A2) veya topluluk manifesti (A6). |
| Karantina özniteliğini körlemesine silmek (`xattr -d com.apple.quarantine`) | Gatekeeper'ın son savunma hattını kaldırır. İndirmeyi biz doğruladığımız için karantinayı korumak + B1 notarization kontrolü doğru yol. |
| Gatekeeper/notarization atlatma, ad-hoc yeniden imzalama | Kullanıcıyı korumasız bırakır; Developer ID hesabımızı ve notarization'ı riske atar. |
| Imzasız veya Team ID'si değişen güncellemeyi "yine de kur" tek tık | Tedarik zinciri saldırısının tam olarak istediği akış. En fazla: uyarı + vendor sitesini aç. |
| MAS güncellemelerini private CommerceKit / `mas` ile otomatik kurmak | Private API, macOS 15.4'te kırıldı; macOS 26.1 sonrası root gerekiyor ([mas releases](https://github.com/mas-cli/mas/releases)). App Store'u açmak (mevcut davranış) doğru. |
| Setapp/Adobe/Microsoft uygulamalarını kendi kanalı dışından güncellemek | Lisans/entitlement bozulması; A5 ile yönlendirme yap. |
| Installomator label'larını çalıştırmak | Rastgele shell script yürütmek = uzaktan kod çalıştırma; sadece statik veri çıkar (A3). |
| Varsayılan açık telemetri / envanter gönderimi | Gizlilik ve güven kaybı; D2 sadece açık onayla, yerel önizlemeyle. |
| Kırık/cracked uygulama tespiti, "lisans durumu" taraması | Hukuki risk, yanlış pozitif, ürünün amacı dışında. |
| Sunucu tarafı kitle kaynaklı veritabanı (erken aşamada) | MacUpdater'ı kapatan sürdürülebilir olmayan bakım yükü; önce A6 (git tabanlı, sunucusuz). |

---

## 4. Önerilen "sonraki 5"

1. **A1 Electron kaynağı (M)** — Rakiplerin en zayıf olduğu, en çok kullanılan uygulama kategorisini kapsama alır; doğrudan "MacUpdater kadar bulmuyor" şikâyetini hedefler.
2. **A4 Kapsam paneli + eksik bildir (S)** — Ucuz, dürüstlük sinyali verir ve sonraki kaynak yatırımlarını veriye dayandırır.
3. **B2 Soak period + C3 koşullu kurulum (S+S, tek ajan)** — Otomatik güncellemeyi güvenli ve "sinir bozmayan" hale getirir; rollback ile birlikte güven hikâyesini tamamlar.
4. **D1 MDM managed preferences (S/M)** — MacUpdater'ın kaçırdığı kurumsal kapıyı açar, G1 gelir modelinin temelidir; mevcut store protokollerine bir katman eklemek yeterli.
5. **A2 Vendor feed tanımları (M)** — Chrome/Firefox/JetBrains/Office gibi yüksek görünürlüklü uygulamaları kod yerine veriyle ekler; A6 topluluk manifestinin formatını da şimdiden belirler.

Bir sonraki dalga: B1 Notarization kontrolü (S, hızlı güvenlik kazancı), C1 CLI (salt-okunur), E1 toplu güncelleme ön-izleme, D3 sürüm tavanı.

---

## 5. Paralel çalışma planı (dosya çakışması analizi)

Ortak sıcak noktalar: `Models/Models.swift` (`UpdateSourceKind`, `AvailableUpdate`), `AppEnvironment.swift` (DI kaydı), `UpdatesViewModel.swift`, `UpdatePolicy.swift`, `ExclusionRules.swift`. Kural: **her sıcak dosyanın tek sahibi olsun**; diğer ajanlar yeni dosya oluşturup protokolle bağlansın, DI kaydını en son "entegrasyon" ajanı yapsın.

| Ajan | Fikirler | Dokunduğu dosyalar | Çakışma notu |
|---|---|---|---|
| 1 — Kaynaklar | A1 (+ sonra A2) | Yeni `Sources/ElectronUpdateSource.swift`, `ElectronFeedParser.swift`, `VendorFeedSource.swift`, `Resources/vendor-feeds.json`; `Models.swift` (`UpdateSourceKind`, `publishedAt`), `DownloadVerifier.swift` (SHA-512) | `Models.swift`'in sahibi bu ajan. `publishedAt` alanını B2 için de bu ajan ekler. |
| 2 — Politika | B2 + C3 + D3 | `Preferences/UpdatePolicy.swift`, `ExclusionRules.swift`, yeni `SystemConditionsProvider.swift`, `Scheduler/UpdateScheduler.swift` | Ajan 1'in `publishedAt` alanına bağımlı → protokolle soyutla veya Ajan 1'den sonra başla. |
| 3 — Kurumsal | D1 (+ sonra D2) | Yeni `Preferences/ManagedPreferencesReader.swift`, `docs/mdm/*.mobileconfig`, yeni `Reports/` modülü | Policy store'larına "decorator" olarak sarılır; `UpdatePolicy.swift`'i düzenlemez. UI kilit simgesi için `SettingsView.swift` sahibi bu ajan. |
| 4 — Kapsam UI | A4 + A5 | Yeni `UI/Coverage/CoverageView.swift`, `Insights/AppWarning.swift`, `InstallMethod.swift` | `MainWindowView.swift` sidebar'a tek satır eklenir — entegrasyon ajanına bırak. |
| 5 — Güvenlik | B1 + B3 | Yeni `Download/GatekeeperAssessor.swift`, `Insights/DownloadHostStore.swift`; `Install/AppInstaller.swift` pipeline adımı | `AppWarning.swift` Ajan 4 ile ortak → yeni vakaları Ajan 4 eklesin ya da sıralı çalıştır. |
| 6 — CLI | C1 (salt-okunur) | `Package.swift` (yeni target), yeni `Sources/appupdater-cli/` | Sadece `AppUpdaterCore` public API'sini tüketir; `Package.swift` başka kimse tarafından düzenlenmemeli. |
| Entegrasyon (son) | DI kayıtları, sidebar, yerelleştirme anahtarları | `AppEnvironment.swift`, `MainWindowView.swift`, `Localizable.xcstrings` | Diğerleri bittikten sonra tek geçişte. |

Bağımsız ve tamamen paralel çalıştırılabilecekler: **Ajan 1, 3, 4, 6**. Ajan 2, Ajan 1'in model değişikliğinden; Ajan 5, Ajan 4'ün `AppWarning` değişikliğinden sonra (veya aynı ajanda birleşik) çalışmalı.
