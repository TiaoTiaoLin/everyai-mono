import 'dart:typed_data';

import '../domain/hidden_instructions.dart';

import '../domain/builtin_skills.dart';
import '../domain/skill_catalog.dart';
import '../domain/skill_format.dart' show SkillRules;
import 'skill_import.dart';
import 'skill_store_stub.dart' if (dart.library.io) 'skill_store_io.dart' as impl;

/// The folders skills are read from.
typedef SkillRoots = ({String? library, String? shared, List<({String id, String path})> projects});

/// Where a project keeps its skills (the cross-tool `.agents/skills`).
const projectSkillsDir = '.agents/skills';

/// The EveryAI skills folder (app support `skills/`) and the shared
/// `~/.agents/skills`; nulls where there is no file system.
Future<SkillRoots> skillRoots(List<({String id, String path})> projects) => impl.roots(projects);

/// Every skill folder under [roots], checked leniently and hashed.
Future<List<InstalledSkill>> scanSkills(SkillRoots roots) => impl.scan(roots);

/// The files under folder [path], for [findImportCandidates].
Future<List<SkillFile>> folderFiles(String path) => impl.folderFiles(path);

/// The skills in a zip file's [bytes].
List<SkillFile> zipSkillFiles(Uint8List bytes) => zipFiles(bytes);

/// Copies [candidate] into `<destDir>/<name>`. Throws [StateError] when it
/// failed its check or a skill of that name is already there.
Future<String> installSkill(ImportCandidate candidate, String destDir) => impl.install(candidate, destDir);

/// Deletes the skill's folder.
Future<void> deleteSkill(InstalledSkill skill) => impl.delete(skill.dir);

/// The bytes of file [rel] (relative, `/`-separated) inside skill folder
/// [dir]; null when it is missing, a link, over [maxBytes] or outside [dir].
Future<List<int>?> readSkillFileBytes(String dir, String rel, {int maxBytes = 512 * 1024}) =>
    impl.readFile(dir, rel, maxBytes);

/// Copies the bundled skills into the library folder [libraryDir]. A skill is
/// written when new or when the app ships a newer copy than the one it
/// installed; one the user removed stays removed, and a folder of the same
/// name the user made is left alone.
Future<void> seedBuiltinSkills(String libraryDir, List<BuiltinSkill> skills) => impl.seedBuiltins(libraryDir, skills);

/// Hidden or suspicious text in [skill]: its `SKILL.md` findings plus a scan of its bundled text files. Read when the
/// user opens the trust review, so a scan of every skill folder at each session start stays cheap.
Future<List<InstructionFinding>> scanSkillFolder(InstalledSkill skill) async {
  final out = [...skill.report.findings];
  for (final rel in skill.files) {
    if (rel == 'SKILL.md') continue;
    final bytes = await readSkillFileBytes(skill.dir, rel, maxBytes: SkillRules.maxFileBytes);
    if (bytes != null) {
      if (scannedText(bytes) case final t?) out.addAll(scanInstructions(t, file: rel));
    }
  }
  return out;
}
