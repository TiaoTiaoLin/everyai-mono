import '../../../skills/domain/skill_catalog.dart';
import 'skill_export.dart' show ExportResult;

Future<ExportResult> exportSkills(String sessionDir, List<InstalledSkill> skills, String sessionText) async =>
    (skillDir: '', names: const <String>[], written: 0, skipped: const <String>[]);

Future<void> removeBriefing(String sessionDir) async {}
