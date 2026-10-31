import 'package:flutter/foundation.dart';

/// Wire identifier of a model, exactly as the backend expects it
/// (`anthropic/claude-haiku-5.5`). An extension type: zero runtime cost, but
/// can't be confused with other strings.
extension type const ModelId(String value) implements Object {}

/// A model vendor, from the id's prefix (`anthropic/…` → anthropic). Known
/// vendors have a product name and a logo; the rest get a monogram.
@immutable
final class ModelProvider {
  const ModelProvider._(this.slug, this.label, this.company, [this.asset]);

  factory ModelProvider.of(String slug) {
    final s = slug.startsWith('~') ? slug.substring(1) : slug;
    return _known[s] ?? ModelProvider._(s, _titleCase(s), _titleCase(s));
  }

  static ModelProvider ofModel(ModelId id) {
    final slash = id.value.indexOf('/');
    return ModelProvider.of(slash == -1 ? id.value : id.value.substring(0, slash));
  }

  final String slug;

  /// Product name shown in the UI ("Claude").
  final String label;
  final String company;

  /// Logo asset, when the app ships one.
  final String? asset;

  static const openai = ModelProvider._('openai', 'ChatGPT', 'OpenAI', 'assets/models/chatgpt.webp');
  static const anthropic = ModelProvider._('anthropic', 'Claude', 'Anthropic', 'assets/models/claude.webp');
  static const google = ModelProvider._('google', 'Gemini', 'Google', 'assets/models/gemini.png');
  static const xai = ModelProvider._('x-ai', 'Grok', 'xAI', 'assets/models/xai.webp');
  static const meta = ModelProvider._('meta-llama', 'Llama', 'Meta', 'assets/models/Llama.jpeg');

  /// The router (`everyai/auto`); drawn with the round EveryAI avatar.
  static const everyai = ModelProvider._('everyai', 'EveryAI', 'EveryAI');

  static final _known = <String, ModelProvider>{
    for (final p in const [openai, anthropic, google, xai, meta, everyai]) p.slug: p,
    'meta': meta,
    'deepseek': const ModelProvider._('deepseek', 'DeepSeek', 'DeepSeek'),
    'qwen': const ModelProvider._('qwen', 'Qwen', 'Alibaba'),
    'mistralai': const ModelProvider._('mistralai', 'Mistral', 'Mistral AI'),
    'z-ai': const ModelProvider._('z-ai', 'GLM', 'Z.ai'),
    'moonshotai': const ModelProvider._('moonshotai', 'Kimi', 'Moonshot AI'),
    'minimax': const ModelProvider._('minimax', 'MiniMax', 'MiniMax'),
    'nvidia': const ModelProvider._('nvidia', 'Nemotron', 'NVIDIA'),
    'perplexity': const ModelProvider._('perplexity', 'Perplexity', 'Perplexity'),
    'cohere': const ModelProvider._('cohere', 'Command', 'Cohere'),
    'amazon': const ModelProvider._('amazon', 'Nova', 'Amazon'),
    'microsoft': const ModelProvider._('microsoft', 'Phi', 'Microsoft'),
    'tencent': const ModelProvider._('tencent', 'Hunyuan', 'Tencent'),
    'bytedance-seed': const ModelProvider._('bytedance-seed', 'Seed', 'ByteDance'),
    'xiaomi': const ModelProvider._('xiaomi', 'MiMo', 'Xiaomi'),
    'openrouter': const ModelProvider._('openrouter', 'OpenRouter', 'OpenRouter', 'assets/models/openrouter.png'),
    'xingchen-agi': const ModelProvider._('xingchen-agi', 'Xing', 'TeleAI'),
    'dots-studio': const ModelProvider._('dots-studio', 'Dots', 'Dots Studio'),
  };

  static String _titleCase(String slug) => slug
      .split(RegExp('[-_]'))
      .where((w) => w.isNotEmpty)
      .map((w) => w.length <= 2 ? w.toUpperCase() : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  @override
  bool operator ==(Object other) => other is ModelProvider && other.slug == slug;

  @override
  int get hashCode => slug.hashCode;

  @override
  String toString() => 'ModelProvider($slug)';
}

enum Modality {
  text('Text'),
  image('Image');

  const Modality(this.label);
  final String label;
}

@immutable
final class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.provider,
    required this.name,
    this.blurb = '',
    this.output = Modality.text,
    this.imageInput = false,
    this.inputs = const {'text'},
    this.contextLength = 0,
    this.promptPrice,
    this.completionPrice,
    this.free = false,
    this.tools = true,
    this.reasoning = false,
    this.featured = false,
    this.created,
  });

  /// One entry of `GET /v1/models`.
  static ModelSpec? fromJson(Object? json) {
    if (json case {'id': final String id}) {
      final m = json as Map<String, Object?>;
      final outputs = (m['output_modalities'] as List<Object?>?) ?? const [];
      final inputs = (m['input_modalities'] as List<Object?>?) ?? const [];
      return ModelSpec(
        id: ModelId(id),
        provider: ModelProvider.ofModel(ModelId(id)),
        name: m['name'] as String? ?? id,
        blurb: m['blurb'] as String? ?? '',
        output: outputs.contains('image') ? Modality.image : Modality.text,
        imageInput: inputs.contains('image'),
        inputs: inputs.whereType<String>().toSet(),
        contextLength: (m['context_length'] as num?)?.toInt() ?? 0,
        promptPrice: (m['prompt_per_mtok'] as num?)?.toDouble(),
        completionPrice: (m['completion_per_mtok'] as num?)?.toDouble(),
        free: m['free'] as bool? ?? false,
        tools: m['tools'] as bool? ?? false,
        reasoning: m['reasoning'] as bool? ?? false,
        featured: m['default'] as bool? ?? false,
        created: switch (m['created']) {
          final num s when s > 0 => DateTime.fromMillisecondsSinceEpoch(s.toInt() * 1000),
          _ => null,
        },
      );
    }
    return null;
  }

  /// A model the catalog doesn't list (an old chat's model, an offline start).
  factory ModelSpec.unknown(ModelId id) {
    final slash = id.value.indexOf('/');
    return ModelSpec(id: id, provider: ModelProvider.ofModel(id), name: id.value.substring(slash + 1));
  }

  final ModelId id;
  final ModelProvider provider;
  final String name;
  final String blurb;
  final Modality output;
  final bool imageInput;

  /// The catalog's `input_modalities`: text, image, file (PDF), audio, video.
  final Set<String> inputs;
  final int contextLength;

  /// USD per million tokens, markup included. Null when not known yet.
  final double? promptPrice;
  final double? completionPrice;

  /// Costs nothing on every plan.
  final bool free;
  final bool tools;
  final bool reasoning;

  /// One of the models every new user starts with.
  final bool featured;
  final DateTime? created;

  bool get supportsStreaming => output == Modality.text;

  /// EveryAI · Auto: the server picks the model, mode and rich answers per turn.
  bool get isAuto => id == autoModelId;

  /// The name without its vendor's product name, for tight places:
  /// "Claude Sonnet 5.5" → "Sonnet 5.5"; "GPT-6.1 Sol" stays.
  String get shortName {
    final prefix = '${provider.label} ';
    return name.startsWith(prefix) && name.length > prefix.length ? name.substring(prefix.length) : name;
  }

  /// "$2.30 / $11.50" per million input / output tokens, or "Free".
  String? get priceLabel {
    if (free) return 'Free';
    if (promptPrice == null || completionPrice == null) return null;
    return '${_usd(promptPrice!)} / ${_usd(completionPrice!)}';
  }

  /// "1M", "262K".
  String get contextLabel => contextLength >= 1000000
      ? '${(contextLength / 1000000).toStringAsFixed(contextLength % 1000000 == 0 ? 0 : 1)}M'
      : '${(contextLength / 1000).round()}K';

  static String _usd(double v) => v >= 10 || v == 0
      ? '\$${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2)}'
      : '\$${v.toStringAsFixed(v < 0.1 ? 3 : 2)}';

  @override
  bool operator ==(Object other) => other is ModelSpec && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ModelSpec(${id.value})';
}

/// Immutable, indexed model registry: lookup by id, by provider and by @mention
/// alias. Featured models come first, then newest first.
final class ModelCatalog {
  ModelCatalog(Iterable<ModelSpec> specs, {required ModelId defaultModel}) : _default = defaultModel {
    // Auto is always there, as the app describes it (whatever `/v1/models` says of it).
    final sorted = [autoModel, ...specs.where((s) => s.id != autoModelId)]
      ..sort((a, b) {
        if (a.featured != b.featured) return a.featured ? -1 : 1;
        if (a.featured) return _featuredRank(a.id).compareTo(_featuredRank(b.id));
        return (b.created ?? DateTime(0)).compareTo(a.created ?? DateTime(0));
      });
    _byId = Map.unmodifiable({for (final s in sorted) s.id: s});
    _byProvider = Map.unmodifiable(_groupByProvider(sorted));
    _aliases = Map.unmodifiable(_buildAliases(sorted));
  }

  late final Map<ModelId, ModelSpec> _byId;
  late final Map<ModelProvider, List<ModelSpec>> _byProvider;
  late final Map<String, ModelSpec> _aliases;
  final ModelId _default;

  Iterable<ModelSpec> get all => _byId.values;
  int get length => _byId.length;
  Iterable<ModelProvider> get providers => _byProvider.keys;
  ModelSpec get defaultModel => _byId[_default] ?? _byId.values.firstOrNull ?? ModelSpec.unknown(_default);

  /// By id; ids saved by older app versions (`claude-haiku-5-5`) resolve by alias.
  ModelSpec? operator [](ModelId id) => _byId[id] ?? _aliases[_normalize(id.value)];

  /// Like `[]`, but never null: unknown ids get a placeholder spec.
  ModelSpec resolve(ModelId id) => this[id] ?? ModelSpec.unknown(id);

  List<ModelSpec> byProvider(ModelProvider p) => _byProvider[p] ?? const [];

  /// The provider's first model (featured first) is its flagship.
  ModelSpec? flagship(ModelProvider p) => _byProvider[p]?.firstOrNull;

  /// Resolves an @mention token (without the @), case-insensitive: a model id
  /// (`anthropic/claude-haiku-5.5`), its name part (`claude-haiku-5.5`), a
  /// provider label (`claude`, `gemini`) or a short alias (`gpt`).
  ModelSpec? resolveMention(String token) => _aliases[_normalize(token)];

  /// Aliases starting with [prefix], for the @ autocomplete.
  Iterable<(String alias, ModelSpec spec)> mentionSuggestions(String prefix) {
    final p = _normalize(prefix);
    final seen = <ModelId>{};
    return _aliases.entries.where((e) => e.key.startsWith(p) && seen.add(e.value.id)).map((e) => (e.key, e.value));
  }

  /// Featured models in the built-in seed's order (Claude, GPT, free).
  static int _featuredRank(ModelId id) {
    final i = _featuredOrder.indexOf(id);
    return i == -1 ? _featuredOrder.length : i;
  }

  static const _featuredOrder = [
    autoModelId,
    ModelId('anthropic/claude-haiku-5.5'),
    ModelId('anthropic/claude-sonnet-5.5'),
    ModelId('anthropic/claude-opus-5.5'),
    ModelId('openai/gpt-6.1-sol'),
    ModelId('openai/gpt-6.1-terra'),
    ModelId('openai/gpt-5.4-mini'),
    ModelId('xingchen-agi/xing4.0-29b-a4b:free'),
    ModelId('dots-studio/dots-3-note-preview:free'),
  ];

  static String _normalize(String s) => s.toLowerCase().replaceAll('.', '-');

  static Map<ModelProvider, List<ModelSpec>> _groupByProvider(Iterable<ModelSpec> specs) {
    final out = <ModelProvider, List<ModelSpec>>{};
    for (final s in specs) {
      (out[s.provider] ??= []).add(s);
    }
    return {for (final e in out.entries) e.key: List.unmodifiable(e.value)};
  }

  static Map<String, ModelSpec> _buildAliases(List<ModelSpec> specs) {
    final out = <String, ModelSpec>{};
    for (final s in specs) {
      out.putIfAbsent(_normalize(s.id.value), () => s);
      final slash = s.id.value.indexOf('/');
      if (slash != -1) out.putIfAbsent(_normalize(s.id.value.substring(slash + 1)), () => s);
    }
    // Provider names map to that provider's flagship (featured first).
    for (final s in specs) {
      out.putIfAbsent(_normalize(s.provider.label), () => s);
      out.putIfAbsent(_normalize(s.provider.slug), () => s);
    }
    final gpt = specs.where((s) => s.provider == ModelProvider.openai).firstOrNull;
    if (gpt != null) {
      out.putIfAbsent('gpt', () => gpt);
      out.putIfAbsent('chatgpt', () => gpt);
    }
    final image = specs.where((s) => s.output == Modality.image).firstOrNull;
    if (image != null) out.putIfAbsent('image', () => image);
    return out;
  }
}

const defaultModelId = ModelId('anthropic/claude-haiku-5.5');

const autoModelId = ModelId('everyai/auto');

/// EveryAI · Auto, the router: the backend picks the model, the mode and
/// rich answers for each turn and says which in a `route` event. It takes
/// what the Claude models take. No effort menu ([reasoning] off: the routed
/// model thinks as its route says), and [tools] off so Code's model lists,
/// which want a concrete model, leave it out.
const autoModel = ModelSpec(
  id: autoModelId,
  provider: ModelProvider.everyai,
  name: 'EveryAI · Auto',
  blurb: 'Picks the model and mode for each message',
  imageInput: true,
  inputs: {'text', 'image', 'file'},
  contextLength: 1000000,
  tools: false,
  featured: true,
);

/// What the app knows before the backend's catalog arrives: the featured models.
final builtInCatalog = ModelCatalog(const [
  ModelSpec(
    id: ModelId('anthropic/claude-haiku-5.5'),
    provider: ModelProvider.anthropic,
    name: 'Claude Haiku 5.5',
    blurb: 'Fast and inexpensive',
    imageInput: true,
    contextLength: 1000000,
    reasoning: true,
    featured: true,
  ),
  ModelSpec(
    id: ModelId('anthropic/claude-sonnet-5.5'),
    provider: ModelProvider.anthropic,
    name: 'Claude Sonnet 5.5',
    blurb: 'Balanced for everyday work',
    imageInput: true,
    contextLength: 1000000,
    reasoning: true,
    featured: true,
  ),
  ModelSpec(
    id: ModelId('anthropic/claude-opus-5.5'),
    provider: ModelProvider.anthropic,
    name: 'Claude Opus 5.5',
    blurb: 'Most capable',
    imageInput: true,
    contextLength: 1000000,
    reasoning: true,
    featured: true,
  ),
  ModelSpec(
    id: ModelId('openai/gpt-6.1-sol'),
    provider: ModelProvider.openai,
    name: 'GPT-6.1 Sol',
    blurb: 'OpenAI reasoning model',
    imageInput: true,
    contextLength: 1050000,
    reasoning: true,
    featured: true,
  ),
  ModelSpec(
    id: ModelId('openai/gpt-6.1-terra'),
    provider: ModelProvider.openai,
    name: 'GPT-6.1 Terra',
    blurb: 'Mid-tier GPT-6.1',
    imageInput: true,
    contextLength: 1050000,
    reasoning: true,
    featured: true,
  ),
  ModelSpec(
    id: ModelId('openai/gpt-5.4-mini'),
    provider: ModelProvider.openai,
    name: 'GPT-5.4 Mini',
    blurb: 'Fast and efficient',
    imageInput: true,
    contextLength: 400000,
    reasoning: true,
    featured: true,
  ),
  ModelSpec(
    id: ModelId('xingchen-agi/xing4.0-29b-a4b:free'),
    provider: ModelProvider._('xingchen-agi', 'Xing', 'TeleAI'),
    name: 'Xing4.0 29B A4B (free)',
    blurb: 'Open-weight mixture of experts',
    contextLength: 262144,
    free: true,
    reasoning: true,
    featured: true,
  ),
  ModelSpec(
    id: ModelId('dots-studio/dots-3-note-preview:free'),
    provider: ModelProvider._('dots-studio', 'Dots', 'Dots Studio'),
    name: 'Dots3-Note Preview (free)',
    blurb: 'Open-weight mixture of experts',
    imageInput: true,
    contextLength: 512000,
    free: true,
    reasoning: true,
    featured: true,
  ),
], defaultModel: defaultModelId);
