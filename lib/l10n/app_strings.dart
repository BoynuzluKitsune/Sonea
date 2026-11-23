import 'dart:ui' as ui;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage { tr, en }

class AppStrings {
  const AppStrings(this.language);

  final AppLanguage language;

  bool get isTurkish => language == AppLanguage.tr;

  // Tabs
  String get tabLibrary => isTurkish ? 'Kütüphane' : 'Library';
  String get tabPlaylists => isTurkish ? 'Çalma Listeleri' : 'Playlists';
  String get tabSettings => isTurkish ? 'Ayarlar' : 'Settings';

  // Library Sub-tabs
  String get subTabTracks => isTurkish ? 'Şarkılar' : 'Tracks';
  String get subTabAlbums => isTurkish ? 'Albümler' : 'Albums';
  String get subTabArtists => isTurkish ? 'Sanatçılar' : 'Artists';
  String get tabFiles => isTurkish ? 'Dosyalar' : 'Files';

  // Count formatters (Turkish uses singular noun after numbers; English singular/plural)
  String trackCountLabel(int count) => isTurkish
      ? '$count şarkı'
      : '$count ${count == 1 ? 'track' : 'tracks'}';

  String albumCountLabel(int count) => isTurkish
      ? '$count albüm'
      : '$count ${count == 1 ? 'album' : 'albums'}';

  String tracksIndexedLabel(int count) => isTurkish
      ? '$count şarkı indekslendi'
      : '$count ${count == 1 ? 'track' : 'tracks'} indexed';

  String tracksReadyLabel(int count) => isTurkish
      ? '$count şarkı hazır'
      : '$count ${count == 1 ? 'track' : 'tracks'} ready';

  String fileCountLabel(int count) => isTurkish
      ? '$count dosya'
      : '$count ${count == 1 ? 'file' : 'files'}';

  String foldersHiddenLabel(int count) => isTurkish
      ? '$count klasör gizli'
      : '$count ${count == 1 ? 'folder' : 'folders'} hidden';

  // Library UI
  String get libraryTitle => isTurkish ? 'Kütüphane' : 'Library';
  String get searchPlaceholder => isTurkish
      ? 'Şarkı, albüm, sanatçı ara...'
      : 'Search tracks, albums, artists...';
  String get scanButton => isTurkish ? 'Yenile' : 'Scan';
  String get scanMusicAction => isTurkish ? 'Müzikleri Tara' : 'Scan Music';
  String get preparingLibrary =>
      isTurkish ? 'Kütüphane hazırlanıyor...' : 'Preparing library...';
  String get noMusicFound => isTurkish
      ? 'Müzik bulunamadı. Taramak için yenile butonuna basın.'
      : 'No music found. Scan your device to get started.';
  String get noAlbumsFound => isTurkish ? 'Albüm bulunamadı' : 'No albums found';
  String get noArtistsFound =>
      isTurkish ? 'Sanatçı bulunamadı' : 'No artists found';
  String scanProgress(int processed, int total, int unreadable) => isTurkish
      ? '$processed / $total · $unreadable okunamadı'
      : '$processed / $total · $unreadable unreadable';
  String scanningLiveCounter(int processed, int total) {
    if (total > 0) {
      return isTurkish
          ? 'Taranıyor: $processed / $total şarkı'
          : 'Scanning: $processed / $total tracks';
    }
    return isTurkish ? 'Müzikler taranıyor...' : 'Scanning audio files...';
  }

  String scanSummary(int indexed, int skipped, int unreadable, int ms) =>
      isTurkish
          ? 'Tarama: $indexed eklendi · $skipped atlandı · $unreadable okunamadı · ${ms}ms'
          : 'Scan: $indexed indexed · $skipped skipped · $unreadable unreadable · ${ms}ms';

  // Permissions
  String get permissionRequired => isTurkish
      ? 'Sonea yerel kütüphanenizi oluşturmak için ses dosyalarına erişim izni gerektirir.'
      : 'Sonea needs audio access to build your local library.';
  String get permissionSettingsRequired => isTurkish
      ? 'Müziklerinizi taramak için lütfen uygulama ayarlarından ses izni verin.'
      : 'Allow audio access in app settings to scan your music.';
  String get allowAccess => isTurkish ? 'İzin Ver' : 'Allow audio access';
  String get openSettings => isTurkish ? 'Ayarları Aç' : 'Open app settings';

  // Playback / Mini Player / Now Playing
  String get noTrackSelected =>
      isTurkish ? 'Şarkı seçilmedi' : 'No track selected';
  String get unknownArtist =>
      isTurkish ? 'Bilinmeyen Sanatçı' : 'Unknown Artist';
  String get unknownAlbum => isTurkish ? 'Bilinmeyen Albüm' : 'Unknown Album';
  String get coverTab => isTurkish ? 'Kapak' : 'Cover';
  String get lyricsTab => isTurkish ? 'Sözler' : 'Lyrics';
  String get tooltipPlay => isTurkish ? 'Oynat' : 'Play';
  String get tooltipPause => isTurkish ? 'Duraklat' : 'Pause';
  String get tooltipNext => isTurkish ? 'Sonraki' : 'Next';
  String get tooltipPrevious => isTurkish ? 'Önceki' : 'Previous';
  String get tooltipShuffle => isTurkish ? 'Karıştır' : 'Shuffle';
  String get tooltipRepeat => isTurkish ? 'Tekrarla' : 'Repeat';
  String get tooltipFavorite => isTurkish ? 'Favori' : 'Favorite';
  String get tooltipMore => isTurkish ? 'Diğer' : 'More';
  String get tooltipMute => isTurkish ? 'Sesi Kapat' : 'Mute';
  String get tooltipUnmute => isTurkish ? 'Sesi Aç' : 'Unmute';

  // Modal Actions
  String get menuQueue => isTurkish ? 'Oynatma Sırası' : 'Current Queue';
  String get menuSleepTimer =>
      isTurkish ? 'Uyku Zamanlayıcısı' : 'Sleep Timer';
  String get menuTrackInfo => isTurkish ? 'Şarkı Bilgisi' : 'Track Information';
  String get infoYear => isTurkish ? 'Yıl' : 'Year';
  String get infoDuration => isTurkish ? 'Süre' : 'Duration';
  String get infoFormat => isTurkish ? 'Format' : 'Format';
  String get infoSampleRate => isTurkish ? 'Örnekleme' : 'Sample Rate';
  String get infoBitDepth => isTurkish ? 'Bit Derinliği' : 'Bit Depth';
  String get infoBitrate => isTurkish ? 'Bit Hızı' : 'Bitrate';
  String get infoReplayGain => 'ReplayGain';
  String get infoPath => isTurkish ? 'Dosya' : 'Path';
  String get close => isTurkish ? 'Kapat' : 'Close';
  String get cancel => isTurkish ? 'İptal' : 'Cancel';
  String get done => isTurkish ? 'Bitti' : 'Done';

  // Synced Lyrics UI, Modes & Manual Picker
  String get modeOff => isTurkish ? 'Kapalı' : 'Off';
  String get modeUnder => isTurkish ? 'Aあ Altta' : 'Aあ Under';
  String get modeLatin => isTurkish ? 'Aa Latin' : 'Aa Latin';
  String get noLyricsSaved =>
      isTurkish ? 'Şarkı sözü bulunamadı' : 'No lyrics saved';
  String get retry => isTurkish ? 'Tekrar Dene' : 'Retry';
  String get alreadyLatin => isTurkish
      ? 'Bu şarkı zaten Latin alfabesinde'
      : 'Already in Latin script';
  String get searchLyrics => isTurkish ? 'Söz Ara' : 'Search Lyrics';
  String get searchLyricsShort => isTurkish ? 'Söz Ara' : 'Search';
  String get retryLyrics => isTurkish ? 'Yeniden Dene' : 'Retry';
  String get pasteLyricsAction =>
      isTurkish ? 'Manuel Yapıştır' : 'Paste Manually';
  String get searchLyricsTab => isTurkish ? 'Çevrimiçi Ara' : 'Search Online';
  String get pasteLyricsTab =>
      isTurkish ? 'Söz Yapıştır / Düzenle' : 'Paste / Edit Lyrics';
  String get pasteLyricsHint => isTurkish
      ? 'Düz metin veya [00:12.50] zaman damgalı LRC sözlerini buraya yapıştırın...'
      : 'Paste plain text or timestamped [00:12.50] LRC lyrics here...';
  String get saveLyricsAction =>
      isTurkish ? 'Sözleri Kaydet' : 'Save Lyrics';
  String get pasteLyricsEmptyError => isTurkish
      ? 'Lütfen kaydetmeden önce şarkı sözü girin.'
      : 'Please enter lyrics before saving.';
  String get searchLyricsTitle =>
      isTurkish ? 'Şarkı Sözü Ara ve Seç' : 'Search & Pick Lyrics';
  String get searchLyricsQueryLabel =>
      isTurkish ? 'Şarkı Adı' : 'Track Title';
  String get searchLyricsArtistLabel =>
      isTurkish ? 'Sanatçı (isteğe bağlı)' : 'Artist (optional)';
  String get searchLyricsButton => isTurkish ? 'Ara' : 'Search';
  String get searchLyricsSearching => isTurkish
      ? 'LRCLIB, KuGou, NetEase ve Musixmatch aranıyor...'
      : 'Searching LRCLIB, KuGou, NetEase & Musixmatch...';
  String get searchLyricsEmpty => isTurkish
      ? 'Eşleşen şarkı sözü bulunamadı. Farklı bir başlık veya sanatçı deneyin.'
      : 'No matching lyrics found. Try editing the title or artist.';
  String get searchLyricsApplied => isTurkish
      ? 'Şarkı sözleri kaydedildi ve uygulandı'
      : 'Lyrics saved and applied';
  String get searchLyricsFailed => isTurkish
      ? 'Arama başarısız oldu. İnternet bağlantınızı kontrol edin.'
      : 'Search failed. Check your internet connection.';
  String get lyricsSyncedBadge => isTurkish ? 'Senkronize' : 'Synced';
  String get lyricsPlainBadge => isTurkish ? 'Düz Metin' : 'Plain';
  String get instrumentalBadge => isTurkish ? 'Enstrümantal' : 'Instrumental';
  String get instrumentalTrackTitle =>
      isTurkish ? 'Enstrümantal Parça' : 'Instrumental Track';
  String get instrumentalTrackSubtitle => isTurkish
      ? 'Bu parçada vokal bulunmuyor — arkanıza yaslanıp müziğin tadını çıkarın.'
      : 'This track has no vocals — sit back and enjoy the music.';
  String get searchLyricsAnyway =>
      isTurkish ? 'Yine de Söz Ara' : 'Search Anyway';
  String get pasteLyricsShort =>
      isTurkish ? 'Söz Yapıştır' : 'Paste Lyrics';
  String get lyricsSourceLrclib => 'LRCLIB';
  String get lyricsSourceKugou => 'KuGou';
  String get lyricsSourceNetease => 'NetEase';
  String get lyricsSourceMusixmatch => 'Musixmatch';
  String get lyricsSourceLyricsOvh => 'Lyrics.ovh';
  String get lyricsSourceGenius => 'Genius';
  String get lyricsSourceEmbedded => isTurkish ? 'Gömülü' : 'Embedded';
  String get lyricsSourceSidecar => isTurkish ? 'Yerel Dosya' : 'Sidecar';
  String get lyricsSourceManual => isTurkish ? 'Manuel' : 'Manual';
  String get lyricsSourceHeuristic =>
      isTurkish ? 'Otomatik Algılama' : 'Auto-Detected';

  String lyricsSourceLabel(String source) {
    final normalized = source.toLowerCase();
    if (normalized.contains('kugou')) return lyricsSourceKugou;
    if (normalized.contains('netease')) return lyricsSourceNetease;
    if (normalized.contains('musixmatch')) return lyricsSourceMusixmatch;
    if (normalized.contains('lrclib')) return lyricsSourceLrclib;
    if (normalized.contains('genius')) return lyricsSourceGenius;
    if (normalized.contains('lyrics_ovh') || normalized.contains('lyrics.ovh')) {
      return lyricsSourceLyricsOvh;
    }
    if (normalized.contains('embedded')) return lyricsSourceEmbedded;
    if (normalized.contains('sidecar')) return lyricsSourceSidecar;
    if (normalized.contains('manual') || normalized.contains('custom')) {
      return lyricsSourceManual;
    }
    if (normalized.contains('heuristic')) return lyricsSourceHeuristic;
    return source;
  }

  String lyricsCoverageBadge(int found, int instrumental, int total) {
    if (instrumental > 0) {
      return isTurkish
          ? '$found / $total · $instrumental enstrümantal'
          : '$found / $total · $instrumental inst.';
    }
    return '$found / $total';
  }

  String lyricsBulkProgress(
    int processed,
    int total,
    int found,
    int instrumental,
    int missing,
  ) {
    if (instrumental > 0) {
      return isTurkish
          ? '$processed / $total — Bulunan: $found · Enstrümantal: $instrumental · Eksik: $missing'
          : '$processed / $total — Found: $found · Instrumental: $instrumental · Missing: $missing';
    }
    return isTurkish
        ? '$processed / $total — Bulunan: $found · Eksik: $missing'
        : '$processed / $total — Found: $found · Missing: $missing';
  }

  String lyricsBulkLastRun(
    int processed,
    int total,
    int found,
    int instrumental,
    int missing,
  ) {
    if (instrumental > 0) {
      return isTurkish
          ? 'Son indirme: $found bulundu · $instrumental enstrümantal · $missing bulunamadı ($processed/$total)'
          : 'Last run: $found found · $instrumental instrumental · $missing missing ($processed/$total)';
    }
    return isTurkish
        ? 'Son indirme: $found bulundu · $missing bulunamadı ($processed/$total)'
        : 'Last run: $found found · $missing missing ($processed/$total)';
  }

  String get lyricsBulkIdleHint => isTurkish
      ? 'Mevcut senkronize sözlü ve enstrümantal parçalar atlanır; eksikler paralel olarak indirilir.'
      : 'Tracks with synced lyrics or marked instrumental are skipped; missing tracks are fetched in parallel.';

  // Settings UI
  String get settingsTitle => isTurkish ? 'Ayarlar' : 'Settings';
  String get searchSettings =>
      isTurkish ? 'Ayarlarda ara...' : 'Search settings...';
  String get languageSection => isTurkish ? 'Uygulama Dili' : 'App Language';
  String get languageTR => 'Türkçe';
  String get languageEN => 'English';

  String get themePacksSection =>
      isTurkish ? 'Sanzo Wada Renk Koleksiyonu' : 'Sanzo Wada Color Collection';
  String get themeGalleryTitle =>
      isTurkish ? 'Tema Galerisi' : 'Theme Gallery';
  String get activeThemeLabel => isTurkish ? 'Aktif Tema' : 'Active Theme';
  String get browseThemesHint => isTurkish
      ? '10 Sanzo Wada paleti · Aydınlık & Karanlık'
      : '10 Sanzo Wada palettes · Light & Dark';
  String get themeCollectionSubtitle => isTurkish
      ? 'Haishoku Soukan (1933–34) — 4 renkli stüdyo paletleri ve özel tipografi'
      : 'Haishoku Soukan (1933–34) — 4-color studio plates & bespoke typography';
  String get lightPlateBadge => isTurkish ? 'Aydınlık' : 'Light';
  String get darkPlateBadge => isTurkish ? 'Karanlık' : 'Dark';
  String get customizationSection =>
      isTurkish ? 'Özelleştirme' : 'Customization';

  String get densityTitle => isTurkish ? 'Liste Yoğunluğu' : 'List Density';
  String get densityCompact => isTurkish ? 'Sıkışık (56px)' : 'Compact (56px)';
  String get densityComfortable =>
      isTurkish ? 'Rahat (72px)' : 'Comfortable (72px)';

  String get cornersTitle => isTurkish ? 'Köşe Yuvarlaklığı' : 'Corner Radius';
  String get cornersSharp => isTurkish ? 'Keskin (4px)' : 'Sharp (4px)';
  String get cornersRounded =>
      isTurkish ? 'Yuvarlatılmış (16px)' : 'Rounded (16px)';
  String get cornersPill => isTurkish ? 'Hap (28px)' : 'Pill (28px)';

  String get seekbarTitle =>
      isTurkish ? 'İlerleme Çubuğu Stili' : 'Seekbar Style';
  String get seekbarWaveform => isTurkish ? 'Dalga Formu' : 'Waveform';
  String get seekbarThinLine => isTurkish ? 'İnce Çizgi' : 'Thin Line';

  String get badgesTitle =>
      isTurkish ? 'Format Rozetlerini Göster' : 'Show Format Badges';
  String get glowTitle =>
      isTurkish ? 'Dinamik Kapak Işığı' : 'Dynamic Cover Glow';

  // Offline Lyrics Section
  String get offlineLyricsTitle =>
      isTurkish ? 'Çevrimdışı Şarkı Sözleri' : 'Offline Lyrics';
  String get downloadAll => isTurkish ? 'Tümünü İndir' : 'Download All';
  String get pauseDownload => isTurkish ? 'Duraklat' : 'Pause';
  String get wifiOnly =>
      isTurkish ? 'Sadece Wi-Fi ile İndir' : 'Download over Wi-Fi Only';
  String get clearLyrics => isTurkish ? 'Sözleri Temizle' : 'Clear Lyrics';
  String get clearConfirm => isTurkish
      ? 'Tüm indirilen şarkı sözlerini silmek istediğinize emin misiniz?'
      : 'Are you sure you want to clear all downloaded lyrics?';
  String lyricsCoverage(int synced, int plain, int notFound, int total) =>
      isTurkish
          ? '$synced / $total senkronize · $plain düz metin · $notFound bulunamadı'
          : '$synced / $total synced · $plain plain · $notFound not found';

  // Smart Playlists & User Playlists
  String get playlistsTitle =>
      isTurkish ? 'Çalma Listeleri' : 'Playlists';
  String get yourPlaylists => isTurkish ? 'Listelerin' : 'Your Playlists';
  String get smartFavorites => isTurkish ? 'Favoriler' : 'Favorites';
  String get smartRecentlyPlayed =>
      isTurkish ? 'Son Çalınanlar' : 'Recently Played';
  String get smartMostPlayed =>
      isTurkish ? 'En Çok Dinlenenler' : 'Most Played';
  String get playAll => isTurkish ? 'Tümünü Oynat' : 'Play All';
  String get shuffleAll => isTurkish ? 'Karıştır' : 'Shuffle';
  String get newShort => isTurkish ? 'Yeni' : 'New';
  String get reorderAction => isTurkish ? 'Sırala' : 'Reorder';
  String get newPlaylist =>
      isTurkish ? 'Yeni Çalma Listesi' : 'New Playlist';
  String get playlistName => isTurkish ? 'Liste Adı' : 'Playlist Name';
  String get create => isTurkish ? 'Oluştur' : 'Create';
  String get rename => isTurkish ? 'Yeniden Adlandır' : 'Rename';
  String get delete => isTurkish ? 'Sil' : 'Delete';
  String get deletePlaylistTitle =>
      isTurkish ? 'Çalma Listesini Sil' : 'Delete Playlist';
  String deletePlaylistConfirm(String name) => isTurkish
      ? '"$name" çalma listesi silinsin mi?'
      : 'Delete playlist "$name"?';
  String get changeCoverImage =>
      isTurkish ? 'Kapak Resmi Değiştir' : 'Change Cover Image';
  String get resetToAutoCollage =>
      isTurkish ? 'Otomatik 2x2 Kolaja Dön' : 'Reset to Auto 2x2 Collage';
  String get coverBadge => isTurkish ? 'Kapak' : 'Cover';
  String get tapArtworkCoverHint => isTurkish
      ? 'Kapağa dokunarak özel görsel seçebilirsin'
      : 'Tap artwork to set a custom cover';
  String get playlistCoverUpdated => isTurkish
      ? 'Çalma listesi kapağı güncellendi.'
      : 'Playlist cover updated.';
  String get playlistCoverReset => isTurkish
      ? 'Otomatik 2x2 kolaj kapağına dönüldü.'
      : 'Reset to automatic 2x2 collage.';
  String get addToPlaylist =>
      isTurkish ? 'Çalma Listesine Ekle' : 'Add to Playlist';
  String get removeFromPlaylist =>
      isTurkish ? 'Listeden Çıkar' : 'Remove from Playlist';
  String get importPlaylist => isTurkish
      ? 'Liste İçe Aktar (.m3u, .pls, .xspf, .csv, .txt)'
      : 'Import Playlist (.m3u, .pls, .xspf, .csv, .txt)';
  String get exportPlaylist =>
      isTurkish ? 'Listeyi Dışa Aktar (.m3u8)' : 'Export Playlist (.m3u8)';
  String get noUserPlaylists => isTurkish
      ? 'Henüz özel çalma listesi oluşturulmadı'
      : 'No user playlists created yet';

  // Sleep Timer
  String get sleepTimerTitle =>
      isTurkish ? 'Uyku Zamanlayıcısı' : 'Sleep Timer';
  String get sleepEndOfTrack =>
      isTurkish ? 'Şarkı bitiminde durdur' : 'At the end of current track';
  String sleepMinutes(int mins) => isTurkish ? '$mins dakika' : '$mins minutes';
  String get cancelTimer =>
      isTurkish ? 'Zamanlayıcıyı İptal Et' : 'Cancel Timer';

  // Backup & Restore
  String get backupSection =>
      isTurkish ? 'Yedekleme ve Geri Yükleme' : 'Backup & Restore';
  String get exportBackup =>
      isTurkish ? 'Yedeği Dışa Aktar (JSON)' : 'Export Backup (JSON)';
  String get importBackup =>
      isTurkish ? 'Yedekten Geri Yükle (JSON)' : 'Import Backup (JSON)';
  String get backupSuccess => isTurkish
      ? 'Yedekleme başarıyla tamamlandı'
      : 'Backup created successfully';
  String get restoreSuccess => isTurkish
      ? 'Geri yükleme başarıyla tamamlandı'
      : 'Restore completed successfully';

  // ReplayGain & Crossfade
  String get replayGainTitle => isTurkish
      ? 'ReplayGain Ses Normalizasyonu'
      : 'ReplayGain Volume Normalization';
  String get replayGainSubtitle => isTurkish
      ? 'Şarkılar arası ses seviyesi farkını otomatik dengeler'
      : 'Automatically balances volume levels across tracks';
  String get replayGainMode =>
      isTurkish ? 'Normalizasyon Modu' : 'Normalization Mode';
  String get replayGainOff => isTurkish ? 'Kapalı' : 'Off';
  String get replayGainTrack => isTurkish ? 'Şarkı' : 'Track';
  String get replayGainAlbum => isTurkish ? 'Albüm' : 'Album';
  String get preAmpTitle =>
      isTurkish ? 'Ön-Amfi Kazancı (Pre-Amp)' : 'Pre-Amp Gain';
  String get crossfadeTitle =>
      isTurkish ? 'Şarkı Geçiş Süresi (Crossfade)' : 'Crossfade Duration';
  String get preventClippingTitle =>
      isTurkish ? 'Bozulmayı Önle (Anti-Clipping)' : 'Prevent Clipping';

  // Opt-in Metadata Editor
  String get editMetadataTitle =>
      isTurkish ? 'Etiket ve Kapak Düzenle' : 'Edit Tags & Cover';
  String get searchMusicBrainz =>
      isTurkish ? 'Çevrimiçi Ara (MusicBrainz)' : 'Search Online (MusicBrainz)';
  String get applyMetadata =>
      isTurkish ? 'Etiketleri Uygula' : 'Apply Metadata';
  String get noCandidates =>
      isTurkish ? 'Çevrimiçi sonuç bulunamadı' : 'No online metadata found';
  String get searching =>
      isTurkish ? 'Müzik veritabanında aranıyor...' : 'Searching MusicBrainz...';
  String get fieldTitle => isTurkish ? 'Şarkı Adı' : 'Title';
  String get fieldArtist => isTurkish ? 'Sanatçı' : 'Artist';
  String get fieldAlbum => isTurkish ? 'Albüm' : 'Album';
  String get musicBrainzResults =>
      isTurkish ? 'MusicBrainz Sonuçları' : 'MusicBrainz Results';
  String get metadataUpdated =>
      isTurkish ? 'Şarkı bilgileri güncellendi' : 'Track metadata updated';

  // Files Tab & Folder Actions
  String folderTrackCount(int count) => trackCountLabel(count);
  String get createPlaylistFromFolder => isTurkish
      ? 'Klasörden Çalma Listesi Oluştur'
      : 'Create Playlist from Folder';
  String get addToExistingPlaylist => isTurkish
      ? 'Var Olan Çalma Listesine Ekle'
      : 'Add to Existing Playlist';
  String addedFolderToPlaylist(int count, String name) => isTurkish
      ? '$count şarkı "$name" listesine eklendi'
      : 'Added $count ${count == 1 ? 'track' : 'tracks'} to "$name"';
  String get noPlaylistsYet =>
      isTurkish ? 'Henüz çalma listesi yok' : 'No playlists yet';
  String get backToFolders =>
      isTurkish ? 'Klasörlere Dön' : 'Back to Folders';
  String get noFilesFound =>
      isTurkish ? 'Klasör bulunamadı' : 'No folders found';

  // Filters & Queue Actions
  String get minDurationTitle =>
      isTurkish ? 'Minimum Şarkı Süresi' : 'Minimum Track Duration';
  String get minDurationOff => isTurkish ? 'Kapalı' : 'Off';
  String secShort(int s) => isTurkish ? '$s sn' : '${s}s';
  String get excludedFoldersTitle => isTurkish
      ? 'Gizlenen / Hariç Tutulan Klasörler'
      : 'Excluded Folders';
  String get hideFolder => isTurkish ? 'Klasörü Gizle' : 'Hide Folder';
  String get folderHidden => isTurkish ? 'Klasör gizlendi' : 'Folder hidden';
  String get undo => isTurkish ? 'Geri Al' : 'Undo';

  String get playNext => isTurkish ? 'Sıradakini Oynat' : 'Play Next';
  String get addToQueue => isTurkish ? 'Sıraya Ekle' : 'Add to Queue';
  String get addedToQueue => isTurkish ? 'Sıraya eklendi' : 'Added to queue';
  String get playNextAdded => isTurkish
      ? 'Sıradaki şarkı olarak ayarlandı'
      : 'Set as next track';
  String selectedCount(int count) =>
      isTurkish ? '$count seçildi' : '$count selected';
  String get selectAll => isTurkish ? 'Tümünü Seç' : 'Select All';
  String get clearSelection => isTurkish ? 'Temizle' : 'Clear';

  // Settings Sections
  String get sectionAppearance =>
      isTurkish ? 'GÖRÜNÜM VE TEMA' : 'APPEARANCE & THEME';
  String get sectionListInterface =>
      isTurkish ? 'LİSTE VE ARAYÜZ' : 'LIST & INTERFACE';
  String get sectionAudioPlayback =>
      isTurkish ? 'SES VE OYNATMA' : 'AUDIO & PLAYBACK';
  String get sectionLyrics => isTurkish ? 'ŞARKI SÖZLERİ' : 'LYRICS';
  String get sectionLibraryScanning =>
      isTurkish ? 'KÜTÜPHANE VE TARAMA' : 'LIBRARY & SCANNING';
  String get sectionBackupRestore =>
      isTurkish ? 'YEDEKLEME VE GERİ YÜKLEME' : 'BACKUP & RESTORE';

  // Subtitles & Settings UI
  String get startupScreenTitle =>
      isTurkish ? 'Açılış Ekranı' : 'Startup Screen';
  String get alphabetScrollerTitle =>
      isTurkish ? 'Alfabe Kaydırıcısını Göster' : 'Show Alphabet Scroller';
  String get alphabetScrollerSubtitle => isTurkish
      ? 'Şarkı listesinin sağında hızlı A-Z harf çubuğunu göster'
      : 'Show fast A-Z index bar on the right edge of track lists';
  String get compactListSubtitle => isTurkish
      ? 'Listede tek ekrana daha fazla şarkı sığdır'
      : 'Fit more tracks on screen with smaller rows';
  String get showBadgesSubtitle => isTurkish
      ? 'Şarkı satırlarında FLAC, M4A, OPUS rozeti göster'
      : 'Show FLAC, M4A, OPUS badges on track rows';
  String get showDurationTitle =>
      isTurkish ? 'Şarkı Süresini Göster' : 'Show Track Duration';
  String get showDurationSubtitle => isTurkish
      ? 'Şarkı satırlarının sağında süreyi (03:42) göster'
      : 'Show duration (03:42) on right side of track rows';
  String get dynamicGlowSubtitle => isTurkish
      ? 'Kapak görselinden ortam ışığı oluştur'
      : 'Create ambient glow from artwork';
  String get equalizerSubtitle => isTurkish
      ? 'Ses frekanslarını ve hazır önayarları düzenle'
      : 'Adjust frequency gains and presets';
  String get equalizerTitle =>
      isTurkish ? '5-Bant Ekolayzır' : '5-Band Equalizer';
  String get timerOff => isTurkish ? 'Zamanlayıcı kapalı' : 'Timer off';
  String get bulkLyricsSubtitle => isTurkish
      ? 'Çevrimdışı erişim için şarkı sözlerini toplu indir'
      : 'Bulk download lyrics for offline playback';
  String get bulkLyricsStarted => isTurkish
      ? 'Şarkı sözleri indirilmeye başlandı'
      : 'Started downloading lyrics';
  String get lyricsCacheCleared =>
      isTurkish ? 'Söz önbelleği temizlendi' : 'Cleared lyrics cache';
  String get clearAutoLyricsTitle =>
      isTurkish ? 'Önbellekteki Sözleri Temizle' : 'Clear Cached Lyrics';
  String get clearAutoLyricsSubtitle => isTurkish
      ? 'Otomatik indirilen sözleri temizler; elle kaydettiklerin korunur'
      : 'Clears auto-fetched lyrics while preserving manually saved lyrics';
  String get clearAutoLyricsDialogTitle => isTurkish
      ? 'Önbellekteki Sözleri Temizle?'
      : 'Clear Auto-Fetched Lyrics Cache?';
  String get clearAutoLyricsDialogBody => isTurkish
      ? 'Otomatik indirilen şarkı sözleri önbellekten silinir ve bir sonraki oynatmada yeni yüksek hassasiyetli motorla tekrar aranır. Elle eklediğiniz özel sözler korunur.'
      : 'Auto-fetched cached lyrics will be cleared and cleanly re-fetched with the strict matching engine. Manually saved lyrics are preserved.';
  String get clearAutoLyricsConfirm => isTurkish ? 'Temizle' : 'Clear';
  String clearAutoLyricsSuccess(int count) {
    if (count == 0) {
      return isTurkish
          ? 'Temizlenecek otomatik söz önbelleği bulunamadı.'
          : 'No auto-fetched cached lyrics to clear.';
    }
    return isTurkish
        ? '$count şarkının söz önbelleği temizlendi.'
        : 'Cleared $count cached ${count == 1 ? 'lyrics entry' : 'lyrics entries'}.';
  }
  String get noFoldersExcluded =>
      isTurkish ? 'Klasör gizlenmedi' : 'No folders excluded';
  String foldersExcludedCount(int count) => isTurkish
      ? '$count klasör gizlendi'
      : '$count ${count == 1 ? 'folder' : 'folders'} excluded';
  String get libraryFiltersTitle =>
      isTurkish ? 'Kütüphane Filtreleri' : 'Library Filters';
  String get addToFavorites =>
      isTurkish ? 'Favorilere Ekle' : 'Add to Favorites';
  String addedTracksToFavorites(int count) => isTurkish
      ? '$count şarkı Favorilere eklendi'
      : 'Added $count ${count == 1 ? 'track' : 'tracks'} to Favorites';

  String get appearanceModeTitle =>
      isTurkish ? 'Görünüm Modu' : 'Appearance Mode';
  String get modeSystem => isTurkish ? 'Sistem' : 'System';
  String get modeLight => isTurkish ? 'Aydınlık' : 'Light';
  String get modeDark => isTurkish ? 'Karanlık' : 'Dark';

  // Sanzo Wada 10 Curated 4-Color Themes (TR & EN)
  String themeName(String packId) {
    switch (packId) {
      case 'wada_255':
        return 'Kuro & Asagi';
      case 'wada_340':
        return isTurkish ? 'Taisho Avangart' : 'Taisho Avant-Garde';
      case 'wada_303':
        return isTurkish ? 'Showa Stüdyo' : 'Showa Studio';
      case 'wada_288':
        return isTurkish ? 'Kenpou Plak' : 'Kenpou Vinyl';
      case 'wada_331':
        return isTurkish ? 'Kachi Çivit' : 'Kachi Indigo';
      case 'wada_271':
        return isTurkish ? 'Tetsu Yeşim' : 'Tetsu Jade';
      case 'wada_329':
        return isTurkish ? 'Kakitsubata Alacası' : 'Kakitsubata Dusk';
      case 'wada_263':
        return isTurkish ? 'Kuriume Seramik' : 'Kuriume Ceramic';
      case 'wada_348':
        return isTurkish ? 'Haishoku Final' : 'Haishoku Finale';
      case 'wada_343':
        return isTurkish ? 'Shiracha Editoryal' : 'Shiracha Editorial';
      default:
        return 'Kuro & Asagi';
    }
  }

  String themeMood(String packId) {
    switch (packId) {
      case 'wada_255':
        return isTurkish
            ? 'Saf odyofil berraklığı · Kalamin & Pirit'
            : 'Crisp audiophile clarity · Calamine & Pyrite';
      case 'wada_340':
        return isTurkish
            ? '1920’ler Tokyo afiş modernizmi · Deniz Yeşili'
            : '1920s Tokyo poster modernism · Sea Green';
      case 'wada_303':
        return isTurkish
            ? 'Analog mastering konsolu · Şeftali & Napoli'
            : 'Analog mastering console · Peach & Naples';
      case 'wada_288':
        return isTurkish
            ? 'Sıcak caz-kissa plak atmosferi · Kehribar'
            : 'Warm jazz-kissa vinyl sleeve · Amber & Sepia';
      case 'wada_331':
        return isTurkish
            ? 'Gece elektroniği & city-pop · Hint Gülü'
            : 'Nocturnal electronic & city-pop · Indian Lake';
      case 'wada_271':
        return isTurkish
            ? 'Sakin mimari denge · Kobalt Yeşili & Nar'
            : 'Calm architectural balance · Cobalt & Lacquer';
      case 'wada_329':
        return isTurkish
            ? 'Süsen alacakaranlık baskısı · Krem & Lavanta'
            : 'Iris twilight woodblock · Cream & Lavender';
      case 'wada_263':
        return isTurkish
            ? 'Dokunsal taş seramik · Tarçın & Turkuaz'
            : 'Tactile stoneware craft · Cinnamon & Turquoise';
      case 'wada_348':
        return isTurkish
            ? 'Klasik konser salonu · Zeytin & Mürdüm'
            : 'Classical concert hall · Olive Buff & Plum';
      case 'wada_343':
        return isTurkish
            ? 'Washi kâğıdı gündüz okuma · Çivit & Toprak'
            : 'Daylight washi bookbinding · Indigo & Sienna';
      default:
        return '';
    }
  }

  // ===========================================================================
  // 4-Step First-Launch Setup Wizard & Smart Defaults
  // ===========================================================================
  String get onboardingSkip => isTurkish ? 'Atla' : 'Skip';
  String get onboardingBack => isTurkish ? 'Geri' : 'Back';
  String get onboardingContinue => isTurkish ? 'Devam Et' : 'Continue';
  String get onboardingStartListening =>
      isTurkish ? "Sonea'ya Başla" : 'Start Listening';
  String get onboardingScanAndStart =>
      isTurkish ? 'Müziğimi Tara ve Başla' : 'Scan My Music & Start';

  // Step 1: Welcome, Language & Appearance
  String get onboardingTagline => isTurkish
      ? 'Sade, çevrimdışı odaklı ve stüdyo kalitesinde yerel müzik deneyimi.'
      : 'Calm, offline-first, studio-grade local music playback.';
  String get onboardingStep1Subtitle => isTurkish
      ? 'Dilini, görünüm modunu ve Sanzo Wada renk paletini seç.'
      : 'Choose your language, brightness mode, and Sanzo Wada palette.';
  String get onboardingPreviewTrack => 'Midnight Echoes';
  String get onboardingPreviewArtist => 'Sonea Studio';

  // Step 2: Music Permission & Smart Library Filter
  String get onboardingStep2Title => isTurkish
      ? 'Müzik İzni ve Akıllı Filtre'
      : 'Music Access & Smart Filter';
  String get onboardingStep2Subtitle => isTurkish
      ? 'Yerel müziklerini indekslemek için izin ver; sesli notları ve zil seslerini otomatik temizle.'
      : 'Grant access to index your local tracks and automatically filter out voice notes & ringtones.';
  String get onboardingPermissionGranted =>
      isTurkish ? 'Ses erişim izni verildi' : 'Audio access granted';
  String get onboardingPermissionPrompt =>
      isTurkish ? 'Yerel ses dosyalarına erişim izni' : 'Local audio files permission';
  String get onboardingGrantPermission =>
      isTurkish ? 'İzin Ver' : 'Grant Permission';
  String get onboardingPermissionBadgeGranted =>
      isTurkish ? 'Verildi' : 'Granted';
  String get onboardingShortAudioTitle =>
      isTurkish ? 'Kısa Ses Filtresi' : 'Short-Audio Filter';
  String get onboardingShortAudioHint => isTurkish
      ? 'WhatsApp sesli notlarını, zil seslerini ve bildirim kliplerini kütüphaneden gizler.'
      : 'Hides WhatsApp voice notes, ringtones, and notification clips from your library.';

  // Step 3: Audio, Visuals & Synced Lyrics
  String get onboardingStep3Title => isTurkish
      ? 'Ses, Görünüm ve Şarkı Sözleri'
      : 'Audio, Visuals & Synced Lyrics';
  String get onboardingStep3Subtitle => isTurkish
      ? 'Oynatma deneyimini ve senkronize karaoke şarkı sözlerini özelleştir.'
      : 'Fine-tune playback visuals, audio normalization, and synced karaoke lyrics.';
  String get seekbarLineShort => isTurkish ? 'İnce Çizgi' : 'Line';
  String get gaplessPlaybackTitle =>
      isTurkish ? 'Boşluksuz Oynatma (Gapless)' : 'Gapless Playback';
  String get gaplessPlaybackSubtitle => isTurkish
      ? 'Canlı konser ve konsept albümlerde parçalar arası sessizliği kaldır'
      : 'Seamless zero-gap transitions between album tracks';
  String get autoFetchLyricsTitle =>
      isTurkish ? 'Senkronize Sözleri Otomatik Getir' : 'Auto-Fetch Synced Lyrics';
  String get autoFetchLyricsSubtitle => isTurkish
      ? 'Çalınan parçalar için 6 sağlayıcıdan zaman damgalı LRC sözlerini otomatik indir'
      : 'Automatically fetch time-synced LRC karaoke lyrics across 6 providers';
  String get romajiTranslitTitle =>
      isTurkish ? 'Romaji / Transliterasyon' : 'Romaji Transliteration';
  String get romajiTranslitSubtitle => isTurkish
      ? 'Japonca, Korece ve Kiril şarkı sözlerinin altında Latin okunuşu göster'
      : 'Display Latin reading beneath Japanese, Korean & Cyrillic lyrics';

  // Step 4: Ready to Listen
  String get onboardingStep4Title =>
      isTurkish ? 'Dinlemeye Hazırsın' : 'Ready to Listen';
  String get onboardingStep4Subtitle => isTurkish
      ? 'Seçtiğin kurulum özeti aşağıda. İstediğin zaman Ayarlar üzerinden değiştirebilirsin.'
      : 'Here is your personalized setup. You can tweak any preference later in Settings.';
  String get onboardingSummaryTheme => isTurkish ? 'Aktif Tema' : 'Active Theme';
  String get onboardingSummaryFilter =>
      isTurkish ? 'Kısa Ses Filtresi' : 'Short-Audio Filter';
  String get onboardingSummarySeekbar =>
      isTurkish ? 'İlerleme Çubuğu' : 'Progress Bar';
  String get onboardingSummaryAudio => isTurkish ? 'Ses Motoru' : 'Audio Engine';
  String get onboardingSummaryLyrics =>
      isTurkish ? 'Şarkı Sözleri & Romaji' : 'Lyrics & Romaji';
  String get statusEnabled => isTurkish ? 'Açık' : 'On';
  String get statusDisabled => isTurkish ? 'Kapalı' : 'Off';
  String get gaplessBadge => isTurkish ? 'Boşluksuz' : 'Gapless';

  String themeModeLabel(String modeName) {
    switch (modeName) {
      case 'light':
        return modeLight;
      case 'dark':
        return modeDark;
      default:
        return modeSystem;
    }
  }

  // Settings General / Setup Convenience Actions
  String get sectionGeneralSetup =>
      isTurkish ? 'Genel ve Kurulum' : 'General & Setup';
  String get rerunSetupWizardTitle =>
      isTurkish ? 'Kurulum Sihirbazını Tekrar Aç' : 'Re-run Setup Wizard';
  String get rerunSetupWizardSubtitle => isTurkish
      ? 'Dil, tema, filtre ve şarkı sözü kurulumunu adım adım yeniden yap'
      : 'Walk through language, theme, library filter, and lyrics setup again';
  String get resetDefaultsTitle =>
      isTurkish ? 'Önerilen Varsayılanlara Sıfırla' : 'Reset to Recommended Defaults';
  String get resetDefaultsSubtitle => isTurkish
      ? 'Çalma listelerini, favorileri ve şarkı sözlerini silmeden tercihleri sıfırla'
      : 'Restore smart defaults without deleting playlists, favorites, or cached lyrics';
  String get resetDefaultsDialogTitle => isTurkish
      ? 'Önerilen Varsayılanlara Sıfırla?'
      : 'Reset to Recommended Defaults?';
  String get resetDefaultsDialogBody => isTurkish
      ? 'Tema, görünüm modu, kısa ses filtresi (30 sn), ReplayGain, boşluksuz oynatma ve şarkı sözü ayarları önerilen değerlere döner. Çalma listeleriniz, favorileriniz ve indirilen şarkı sözleriniz korunur.'
      : 'Theme, appearance mode, short-audio filter (30s), ReplayGain, gapless playback, and lyrics preferences will return to recommended defaults. Your playlists, favorites, and cached lyrics are preserved.';
  String get resetDefaultsConfirm => isTurkish ? 'Sıfırla' : 'Reset';
  String get resetDefaultsSuccess => isTurkish
      ? 'Ayarlar önerilen varsayılanlara sıfırlandı.'
      : 'Settings restored to recommended defaults.';
}

final appLanguageProvider =
    NotifierProvider<AppLanguageNotifier, AppLanguage>(AppLanguageNotifier.new);

class AppLanguageNotifier extends Notifier<AppLanguage> {
  static const _kLangKey = 'app_language_code';

  /// Detects initial language from device locale (`tr` -> Turkish, otherwise English).
  static AppLanguage detectSystemLanguage() {
    final code = ui.PlatformDispatcher.instance.locale.languageCode.toLowerCase();
    return code == 'tr' ? AppLanguage.tr : AppLanguage.en;
  }

  @override
  AppLanguage build() {
    _loadLang();
    return detectSystemLanguage();
  }

  Future<void> _loadLang() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_kLangKey);
    if (code == 'en') {
      state = AppLanguage.en;
    } else if (code == 'tr') {
      state = AppLanguage.tr;
    }
  }

  Future<void> setLanguage(AppLanguage language) async {
    state = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLangKey, language == AppLanguage.tr ? 'tr' : 'en');
  }

  Future<void> resetToSystemDefault() async {
    state = detectSystemLanguage();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLangKey);
  }
}

final stringsProvider = Provider<AppStrings>((ref) {
  final lang = ref.watch(appLanguageProvider);
  return AppStrings(lang);
});
