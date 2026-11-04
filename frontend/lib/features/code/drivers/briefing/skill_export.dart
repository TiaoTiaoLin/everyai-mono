import '../../../skills/domain/skill_catalog.dart';
import 'skill_export_stub.dart' if (dart.library.io) 'skill_export_io.dart' as impl;

/// What an export did: the skill folder to hand to the CLIs, the skills written, how many files changed, and the
/// skills or files left out (with a reason).
typedef ExportResult = ({String skillDir, List<String> names, int written, List<String> skipped});

/// Writes the session's skills under `<sessionDir>/briefing/` as `SKILL.md` folders (agentskills layout), plus the
/// generated `everyai-session` skill and a Claude plugin manifest. The briefing folder is the Claude plugin root, so
/// the one `skills/` folder serves every CLI.
///
/// [skills] must be the caller's fresh `sessionSkills(...)` result: enabled and trusted now. Chat-only skills
/// (`metadata.tool`) and any named `everyai-session` are dropped. Nothing is written outside `<sessionDir>/briefing`:
/// the call refuses when that folder is a link, and replaces links inside it instead of writing through them.
/// Idempotent: files that already match are not touched, and stale ones are removed.
Future<ExportResult> exportSkills(String sessionDir, List<InstalledSkill> skills, {required String sessionSkillMd}) =>
    impl.exportSkills(sessionDir, skills, sessionSkillMd);

/// Deletes `<sessionDir>/briefing` (call when the session is removed). A link there is removed, not followed.
Future<void> removeBriefing(String sessionDir) => impl.removeBriefing(sessionDir);
