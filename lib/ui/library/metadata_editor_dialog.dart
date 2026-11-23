import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/core/app_logger.dart';
import 'package:sonea/core/app_paths.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/src/rust/api/library.dart' as rust_lib;
import 'package:sonea/src/rust/api/metadata.dart' as rust_meta;
import 'package:sonea/theme/sonea_theme_tokens.dart';

class MetadataEditorDialog extends ConsumerStatefulWidget {
  const MetadataEditorDialog({
    super.key,
    required this.track,
    this.onTrackUpdated,
  });

  final rust_lib.Track track;
  final ValueChanged<rust_lib.Track>? onTrackUpdated;

  @override
  ConsumerState<MetadataEditorDialog> createState() => _MetadataEditorDialogState();
}

class _MetadataEditorDialogState extends ConsumerState<MetadataEditorDialog> {
  late TextEditingController _titleController;
  late TextEditingController _artistController;
  late TextEditingController _albumController;

  bool _isSearching = false;
  List<rust_meta.MetadataCandidate> _candidates = [];
  rust_meta.MetadataCandidate? _selectedCandidate;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.track.title);
    _artistController = TextEditingController(text: widget.track.artist ?? '');
    _albumController = TextEditingController(text: widget.track.album ?? '');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    super.dispose();
  }

  Future<void> _searchMusicBrainz() async {
    setState(() {
      _isSearching = true;
      _candidates = [];
    });

    try {
      final title = _titleController.text.trim();
      final artist = _artistController.text.trim().isEmpty ? null : _artistController.text.trim();

      final results = await rust_meta.searchTrackMetadata(
        title: title,
        artist: artist,
      );

      if (mounted) {
        setState(() {
          _isSearching = false;
          _candidates = results;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  void _selectCandidate(rust_meta.MetadataCandidate candidate) {
    setState(() {
      _selectedCandidate = candidate;
      _titleController.text = candidate.title;
      _artistController.text = candidate.artist;
      _albumController.text = candidate.album ?? _albumController.text;
    });
  }

  Future<void> _applyMetadata() async {
    final dbPath = await AppPaths.databasePath();
    final coversDir = await AppPaths.coversDir();

    try {
      final updatedTrack = await rust_meta.applyTrackMetadata(
        dbPath: dbPath,
        coversDir: coversDir,
        trackId: widget.track.id,
        title: _titleController.text.trim(),
        artist: _artistController.text.trim(),
        album: _albumController.text.trim().isEmpty ? null : _albumController.text.trim(),
        year: _selectedCandidate?.year ?? widget.track.year,
        coverUrl: _selectedCandidate?.coverUrl,
      );

      widget.onTrackUpdated?.call(updatedTrack);
      if (mounted) {
        Navigator.pop(context, updatedTrack);
      }
    } catch (e, st) {
      appLog('MetadataEditorDialog', 'applyTrackMetadata failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final tokens = SoneaThemeTokens.of(context);

    return AlertDialog(
      backgroundColor: tokens.surfaceColor,
      title: Text(
        strings.editMetadataTitle,
        style: TextStyle(color: tokens.textColor),
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _titleController,
                style: TextStyle(color: tokens.textColor, fontSize: 14),
                decoration: InputDecoration(
                  labelText: strings.fieldTitle,
                  labelStyle: TextStyle(color: tokens.subtextColor),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _artistController,
                style: TextStyle(color: tokens.textColor, fontSize: 14),
                decoration: InputDecoration(
                  labelText: strings.fieldArtist,
                  labelStyle: TextStyle(color: tokens.subtextColor),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _albumController,
                style: TextStyle(color: tokens.textColor, fontSize: 14),
                decoration: InputDecoration(
                  labelText: strings.fieldAlbum,
                  labelStyle: TextStyle(color: tokens.subtextColor),
                ),
              ),
              const SizedBox(height: 16),

              // Search Online Button
              OutlinedButton.icon(
                onPressed: _isSearching ? null : _searchMusicBrainz,
                icon: const Icon(Icons.cloud_sync, size: 18),
                label: Text(
                  _isSearching ? strings.searching : strings.searchMusicBrainz,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),

              if (_isSearching)
                const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
              else if (_candidates.isNotEmpty) ...[
                Text(
                  strings.musicBrainzResults,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: tokens.subtextColor),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 180,
                  child: ListView.builder(
                    itemCount: _candidates.length,
                    itemBuilder: (context, index) {
                      final c = _candidates[index];
                      final isSelected = _selectedCandidate?.mbid == c.mbid;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? tokens.accentColor.withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected ? tokens.accentColor : Colors.transparent,
                          ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                          leading: SizedBox(
                            width: 36,
                            height: 36,
                            child: c.coverUrl != null
                                ? Image.network(
                                    c.coverUrl!,
                                    cacheWidth: 96,
                                    cacheHeight: 96,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Icon(Icons.music_note, color: tokens.subtextColor),
                                  )
                                : Icon(Icons.music_note, color: tokens.subtextColor),
                          ),
                          title: Text(
                            c.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: tokens.textColor, fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            '${c.artist}${c.album != null ? " • ${c.album}" : ""}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: tokens.subtextColor),
                          ),
                          onTap: () => _selectCandidate(c),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.close),
        ),
        FilledButton(
          onPressed: _applyMetadata,
          child: Text(strings.applyMetadata),
        ),
      ],
    );
  }
}
