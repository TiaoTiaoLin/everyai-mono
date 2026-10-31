import 'package:every_ai/features/chat/domain/chat_session.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = builtInCatalog;

  /// Shaped like `GET /v1/models` entries.
  final remote = ModelCatalog([
    for (final json in [
      {
        'id': 'anthropic/claude-haiku-5.5',
        'name': 'Claude Haiku 5.5',
        'blurb': 'Fast.',
        'context_length': 1000000,
        'input_modalities': ['text', 'image'],
        'output_modalities': ['text'],
        'prompt_per_mtok': 0.115,
        'completion_per_mtok': 0.575,
        'free': false,
        'tools': true,
        'reasoning': true,
        'default': true,
        'created': 1790000000,
      },
      {
        'id': 'google/gemini-3.1-flash-image',
        'name': 'Gemini 3.1 Flash Image',
        'output_modalities': ['image', 'text'],
        'prompt_per_mtok': 0.3,
        'completion_per_mtok': 2.5,
        'created': 1780000000,
      },
      {
        'id': '~openai/gpt-latest',
        'name': 'GPT Latest',
        'prompt_per_mtok': 2.3,
        'completion_per_mtok': 11.5,
        'created': 1791000000,
      },
      {'id': 'qwen/qwen4-32b:free', 'name': 'Qwen4 32B (free)', 'free': true, 'created': 1785000000},
    ])
      ModelSpec.fromJson(json)!,
  ], defaultModel: defaultModelId);

  test('ids are unique; lookups by id and by legacy id', () {
    expect(catalog.all.map((s) => s.id).toSet().length, catalog.all.length);
    expect(catalog[const ModelId('anthropic/claude-haiku-5.5')]?.provider, ModelProvider.anthropic);
    // Ids saved by the previous app version.
    expect(catalog[const ModelId('claude-haiku-5-5')]?.id, const ModelId('anthropic/claude-haiku-5.5'));
    expect(catalog[const ModelId('gpt-5.4-mini')]?.id, const ModelId('openai/gpt-5.4-mini'));
    expect(catalog[const ModelId('nope')], isNull);
    expect(catalog.resolve(const ModelId('mistralai/large-4')).name, 'large-4');
  });

  test('the built-in catalog is the featured models, default first', () {
    expect(catalog.all.every((s) => s.featured), isTrue);
    expect(catalog.defaultModel.id, defaultModelId);
    expect(catalog.all.where((s) => s.free), hasLength(2));
  });

  test('fromJson reads prices, modalities and vendors', () {
    final haiku = remote[const ModelId('anthropic/claude-haiku-5.5')]!;
    expect(haiku.priceLabel, matches(RegExp(r'^\$0\.1\d / \$0\.5\d$')));
    expect(haiku.contextLabel, '1M');
    expect(haiku.imageInput, isTrue);
    expect(remote[const ModelId('google/gemini-3.1-flash-image')]!.output, Modality.image);
    expect(remote[const ModelId('qwen/qwen4-32b:free')]!.priceLabel, 'Free');
    // "~openai/…" aliases belong to the vendor.
    expect(remote[const ModelId('~openai/gpt-latest')]!.provider, ModelProvider.openai);
    expect(ModelProvider.of('some-new-lab').label, 'Some New Lab');
  });

  test('featured first, then newest first', () {
    expect(remote.all.map((s) => s.id.value), [
      'everyai/auto',
      'anthropic/claude-haiku-5.5',
      '~openai/gpt-latest',
      'qwen/qwen4-32b:free',
      'google/gemini-3.1-flash-image',
    ]);
  });

  test('mentions resolve by label, name part, short alias and id (case-insensitive)', () {
    expect(catalog.resolveMention('Claude'), catalog.flagship(ModelProvider.anthropic));
    expect(catalog.resolveMention('gpt'), catalog.flagship(ModelProvider.openai));
    expect(catalog.resolveMention('CLAUDE-OPUS-5.5')?.id, const ModelId('anthropic/claude-opus-5.5'));
    expect(catalog.resolveMention('openai/gpt-6.1-sol')?.id, const ModelId('openai/gpt-6.1-sol'));
    expect(catalog.resolveMention('unknown'), isNull);
  });

  test('mention suggestions are prefix matches without duplicate models', () {
    final s = catalog.mentionSuggestions('cl').toList();
    expect(s, isNotEmpty);
    expect(s.every((e) => e.$1.startsWith('cl')), isTrue);
    expect(s.map((e) => e.$2.id).toSet().length, s.length);
  });

  group('parseMention', () {
    test('leading mention routes and is removed from the prompt', () {
      final r = parseMention('@claude explain monads', catalog);
      expect(r.model?.provider, ModelProvider.anthropic);
      expect(r.prompt, 'explain monads');
    });

    test('inline mention anywhere in the text', () {
      final r = parseMention('draw a cat @image please', remote);
      expect(r.model?.output, Modality.image);
      expect(r.prompt, 'draw a cat please');
    });

    test('emails and unknown handles stay untouched', () {
      final r = parseMention('mail me at a@b.com or @someone', catalog);
      expect(r.model, isNull);
      expect(r.prompt, 'mail me at a@b.com or @someone');
    });
  });

  test('titleFromPrompt uses the first line and truncates', () {
    expect(titleFromPrompt('  Hello\nworld'), 'Hello');
    final long = titleFromPrompt('x' * 100);
    expect(long.length, lessThanOrEqualTo(60));
    expect(long.endsWith('…'), isTrue);
  });

  test('every catalog has EveryAI · Auto first, as the app describes it', () {
    final served = ModelCatalog([
      ModelSpec.fromJson({'id': 'everyai/auto', 'name': 'Server Auto', 'tools': true})!,
      ...remote.all.where((s) => !s.isAuto),
    ], defaultModel: defaultModelId);
    for (final c in [remote, served, builtInCatalog]) {
      final auto = c.all.first;
      expect(auto.id, autoModelId);
      expect(auto.name, 'EveryAI · Auto');
      expect(auto.provider, ModelProvider.everyai);
      // Code's model lists skip it; no effort menu; takes what Claude takes.
      expect(auto.tools, isFalse);
      expect(auto.reasoning, isFalse);
      expect(auto.inputs, containsAll(['image', 'file']));
    }
    expect(remote.defaultModel.id, defaultModelId);
  });

  test('shortName drops the vendor product name', () {
    expect(remote.resolve(const ModelId('anthropic/claude-haiku-5.5')).shortName, 'Haiku 5.5');
    expect(builtInCatalog.resolve(const ModelId('openai/gpt-6.1-sol')).shortName, 'GPT-6.1 Sol');
  });
}
