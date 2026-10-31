import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/api_client.dart';
import '../providers.dart';

/// What one decide question asks for: yes/no, one of a few choices, or a
/// score from 0 to 1.
enum DecideKind { bool, choice, score }

/// One question for `POST /v1/aux/decide`. [id] names its answer.
@immutable
final class DecideQuestion {
  const DecideQuestion.yesNo(this.id, this.prompt) : kind = DecideKind.bool, choices = const [];
  const DecideQuestion.choice(this.id, this.prompt, this.choices) : kind = DecideKind.choice;
  const DecideQuestion.score(this.id, this.prompt) : kind = DecideKind.score, choices = const [];

  final String id;
  final DecideKind kind;
  final String prompt;

  /// The allowed answers of a [DecideKind.choice] question.
  final List<String> choices;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'prompt': prompt,
    if (kind == DecideKind.choice) 'choices': choices,
  };
}

/// One answer: a bool, one of the question's choices, or a score in 0..1;
/// null [value] means unsure (the model said so, or the call failed).
@immutable
final class DecideAnswer {
  const DecideAnswer(this.id, this.value, {this.p});
  const DecideAnswer.unsure(this.id) : value = null, p = null;

  final String id;
  final Object? value;

  /// How sure the model was, when the server says.
  final double? p;

  bool get unsure => value == null;
  bool? get asBool => value is bool ? value as bool : null;
  String? get asChoice => value is String ? value as String : null;
  double? get asScore => value is double ? value as double : null;

  @override
  String toString() => 'DecideAnswer($id: ${value ?? 'unsure'})';
}

/// The answers of one decide call. Every question asked has an answer;
/// [failed] says none came back (error, timeout, out of credits), so every
/// answer is unsure.
@immutable
final class DecideResult {
  const DecideResult(this._answers, {this.model, this.chargedMicros = 0, this.failed = false});

  /// Every question unsure: what callers get when the call fails.
  factory DecideResult.unsure(List<DecideQuestion> questions) =>
      DecideResult({for (final q in questions) q.id: DecideAnswer.unsure(q.id)}, failed: true);

  /// The server's `{answers, model, charged_micros}`, checked against
  /// [questions]: a value of the wrong type, a choice that wasn't offered, a
  /// score outside 0..1 or a missing answer is unsure.
  factory DecideResult.fromJson(Map<String, Object?> json, List<DecideQuestion> questions) {
    final byId = <String, Map<String, Object?>>{
      for (final a in json['answers'] as List<Object?>? ?? const [])
        if (a case {'id': final String id} && final Map<String, Object?> m) id: m,
    };
    return DecideResult(
      {
        for (final q in questions)
          q.id: switch (byId[q.id]) {
            final Map<String, Object?> a => DecideAnswer(
              q.id,
              _checked(q, a['value']),
              p: (a['p'] as num?)?.toDouble(),
            ),
            null => DecideAnswer.unsure(q.id),
          },
      },
      model: json['model'] as String?,
      chargedMicros: (json['charged_micros'] as num?)?.toInt() ?? 0,
    );
  }

  final Map<String, DecideAnswer> _answers;
  final String? model;
  final int chargedMicros;
  final bool failed;

  /// [id]'s answer; unsure when it wasn't asked.
  DecideAnswer operator [](String id) => _answers[id] ?? DecideAnswer.unsure(id);

  Iterable<DecideAnswer> get answers => _answers.values;

  bool get allUnsure => _answers.values.every((a) => a.unsure);

  static Object? _checked(DecideQuestion q, Object? value) => switch ((q.kind, value)) {
    (DecideKind.bool, final bool b) => b,
    (DecideKind.choice, final String s) when q.choices.contains(s) => s,
    (DecideKind.score, final num n) when n >= 0 && n <= 1 => n.toDouble(),
    _ => null, // "unsure", or not what was asked
  };
}

/// Small yes/no/choice/score judgements by a cheap model on the backend
/// (`POST /v1/aux/decide`): risk labels, routing hints. Never throws: any
/// error, a timeout or a 402 gives every question unsure, so callers always
/// have their fallback.
final class DecideClient {
  const DecideClient(this._api, {this.authenticated = false, this.timeout = const Duration(seconds: 8)});

  final ApiClient _api;

  /// Sends the user's JWT; ignored when [decide] gets an `apiKey`.
  final bool authenticated;
  final Duration timeout;

  /// Asks [questions] about [text]. [job] names the kind of judgement
  /// ("risk") for the backend's routing and ledger; [session] attributes the
  /// spend (`X-EveryAI-Session`); [apiKey] (an `sk-eai-` gateway key) is sent
  /// instead of the JWT; [headers] carries BYOK keys.
  Future<DecideResult> decide({
    String? job,
    required String text,
    String? instructions,
    required List<DecideQuestion> questions,
    String? session,
    String? apiKey,
    Map<String, String> headers = const {},
  }) async {
    if (questions.isEmpty) return const DecideResult({});
    try {
      final json = await _api
          .postJson(
            'v1/aux/decide',
            {
              'job': ?job,
              'text': text,
              'instructions': ?instructions,
              'questions': [for (final q in questions) q.toJson()],
            },
            authenticated: apiKey == null && authenticated,
            timeout: timeout,
            headers: {...headers, if (apiKey != null) 'Authorization': 'Bearer $apiKey', 'X-EveryAI-Session': ?session},
          )
          // The client's timeout bounds the first byte; this bounds the whole call.
          .timeout(timeout + const Duration(seconds: 1));
      return DecideResult.fromJson(json, questions);
    } on Object {
      return DecideResult.unsure(questions);
    }
  }
}

final decideClientProvider = Provider<DecideClient>((ref) {
  // With dev auth the backend serves anonymous requests as its dev user.
  return DecideClient(ref.watch(apiClientProvider), authenticated: !ref.watch(appConfigProvider).devSkipAuth);
});
