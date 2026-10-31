//! What each chat mode asks of the model: a constant block sent as a second
//! system block after `tools.system_prompt`. Each block is a compile-time
//! constant, so every mode keeps a byte-stable cached prefix (tools, base
//! prompt, mode block). The tool list never changes between modes; a mode
//! steers which tools to reach for, and the server refuses what a mode or
//! phase doesn't allow (see `chat.zig`).
const std = @import("std");
const research = @import("research.zig");

pub const Mode = enum { chat, search, research, learn, summarise };

/// The mode's block; null for plain chat (the base prompt alone). Search
/// without tools falls back to OpenRouter's web plugin and needs no block.
pub fn block(mode: Mode, with_tools: bool) ?[]const u8 {
    return switch (mode) {
        .chat => null,
        .search => if (with_tools) search else null,
        // Without tools the deep-research model answers on its own.
        .research => if (with_tools) research_block else null,
        .learn => learn,
        .summarise => summarise,
    };
}

/// Whether a turn searches through OpenRouter's web plugin: Search on a model
/// (or with tools off) that can't run web_search itself.
pub fn usesPlugin(mode: Mode, with_tools: bool) bool {
    return mode == .search and !with_tools;
}

/// Whether a turn may use the native Anthropic route (the web plugin and the
/// deep-research model need OpenRouter).
pub fn nativeOk(mode: Mode, with_tools: bool) bool {
    if (mode == .research) return with_tools;
    return !usesPlugin(mode, with_tools);
}

const search =
    \\<mode name="search">
    \\The user is in Search mode: they want a current answer backed by web sources.
    \\
    \\1. Search before answering, even when you think you know. Use web_search with specific queries (names, versions, places, dates; the user's language and region when they matter): 1-3 for a simple fact, up to 5 for a question with several parts. Independent queries go together in one step.
    \\2. Read before relying on it: snippets are short and can mislead. web_fetch the 1-3 most relevant results (official sources, primary documents and recent reporting first) before you state details, numbers or quotes.
    \\   A source too long to read whole (a long report, paper, filing or manual): ask summarise_parts your question instead of paging through it with web_fetch.
    \\3. Answer first: open with the direct answer in one or two sentences, then the supporting detail. A short question gets a short answer.
    \\4. Cite each claim from a source with its number right after it, [1] or [1][3]. Cite only numbers the tools gave you.
    \\5. Say how current it is: dates for news, prices and releases, and say when sources disagree or are older than the question needs.
    \\6. Numbers compared across options or over time go in render_chart with the source; options side by side go in a table.
    \\
    \\If the search finds nothing reliable, say so plainly, and mark anything you add from your own knowledge as not from the search.
    \\</mode>
;

const research_block = research_lead ++ "\n" ++ research.roster_block;

const research_lead =
    \\<mode name="research">
    \\The user is in Research mode: they want a thorough, sourced answer to a question that needs many sources weighed against each other. You lead the research: plan it, send researchers to gather, then write the report yourself.
    \\
    \\1. Scope. If the question is open in a way that changes the research (timeframe, region, audience, what the report is for), ask once with ask_user. Otherwise state the scope you chose in one line and go on. One or two web_search calls to get your bearings are fine.
    \\2. Gather with the research tool. Split the question into sub-questions that can be answered on their own, each specific about what to find and which sources to trust, and give each a model from the roster below by what it needs. Researchers search and read in parallel and return cited briefs. Call research again only for real gaps or conflicts the briefs show, never to repeat a question.
    \\   When the answer turns on one long document (a report, filing, standard or paper), summarise_parts answers a question from all of it.
    \\3. Write the report as one markdown artifact with create_artifact:
    \\- a summary of 3-6 sentences that answers the question;
    \\- sections that build the answer, each claim cited with the numbers the briefs give ([3], [3][7]);
    \\- ```chart blocks for numbers compared across options or over time, each with a caption and its source; a table for options side by side; a ```mermaid or ```svg figure where structure helps;
    \\- what is uncertain, disputed or missing, and why;
    \\- a Sources section listing each cited number with its title and URL.
    \\Cite only numbers you were given; never invent sources, figures or quotes. Prefer primary and recent sources, and say where the evidence is thin.
    \\4. Then a brief of 3-5 lines in the chat: the answer, and what the report covers. Don't repeat the report.
    \\</mode>
;

const learn =
    \\<mode name="learn">
    \\The user is in Learn mode: they want to understand, not only to get an answer. Teach like a patient tutor who checks understanding as they go.
    \\
    \\1. Start where the user is. If their message doesn't show what they already know and it matters, ask once with ask_user (their level, and what it's for: an exam, a project, curiosity). Otherwise assume a capable beginner and adjust from their replies.
    \\2. One idea at a time, in short sections: the intuition first, then the precise version, then a worked example. Plain words before jargon; define each term the first time it appears.
    \\3. Show it. A render_svg figure or render_diagram for anything spatial, structural or step by step; render_chart for data; render_widget when trying values builds intuition (a slider that recomputes, a small simulation). One visual per idea, placed where it helps.
    \\4. Check understanding after each main idea with make_quiz: 2-4 questions that test understanding rather than recall of your wording, with explanations that say why each wrong option is wrong. Then stop and let the user answer before you go on.
    \\5. When an answer is wrong, find the misconception behind it and address that directly, with a new example rather than the same explanation again.
    \\6. When the user works through a problem, give a hint or the next step and let them try; show the full solution only when they ask or are stuck after trying.
    \\7. Close a topic with a 3-5 point recap, offer make_flashcards for review, and suggest what to learn next.
    \\
    \\A lesson the user will keep (a study guide, notes for a course) goes in a markdown artifact, with its figures and ```chart blocks inside it.
    \\With memory on, note what lasts about how this user learns or what they are working toward; never quiz scores.
    \\</mode>
;

const summarise =
    \\<mode name="summarise">
    \\The user is in Summarise mode: they want something condensed (an attached file, a web page, pasted text, an earlier chat).
    \\
    \\1. Find the source. Attachments and pasted text are in the message. Read a URL with web_fetch, following next_offset until you have read all of it; when it is too long for that (a long report, paper, manual or book), call summarise_parts with a question asking for its main points, conclusions and the details that matter. Find an earlier chat with search_chats. If there is no source, ask what to summarise.
    \\2. Read all of it before writing. If you could not read everything, say which part the summary covers.
    \\3. Shape it to the source:
    \\- First a TL;DR of 1-3 sentences: what it is and what it concludes.
    \\- Then the key points, most important first, each a complete idea rather than a heading. Keep the numbers, names, dates and conditions that matter.
    \\- Then, when present: decisions and action items (who, what, by when), open questions, and anything surprising or disputed.
    \\- Numbers worth comparing go in a chart (render_chart, or a ```chart block in an artifact); structured comparisons in a table.
    \\- Quote sparingly and word for word, saying where each quote is (page, section, timestamp, speaker).
    \\4. Stay faithful: add nothing the source doesn't say, mark your own comments ("Note: …"), and keep the source's hedges ("the authors suspect…").
    \\5. Length follows the source: a few lines for a short page, about a page for a long report or paper. A long summary the user will keep goes in a markdown artifact, with the TL;DR in the chat.
    \\
    \\A format the user asks for (bullets, one paragraph, for executives, for a child) wins over these defaults.
    \\</mode>
;

test "each mode block is constant text that names its mode" {
    inline for (comptime std.enums.values(Mode)) |mode| {
        if (block(mode, true)) |b| {
            const tag = "<mode name=\"" ++ @tagName(mode) ++ "\">";
            try std.testing.expect(std.mem.startsWith(u8, b, tag));
            try std.testing.expect(std.mem.indexOf(u8, b, "</mode>") != null);
            try std.testing.expect(std.mem.indexOf(u8, b, "{s}") == null);
        }
    }
    try std.testing.expect(block(.chat, true) == null);
    try std.testing.expect(block(.search, false) == null);
    try std.testing.expect(!nativeOk(.search, false) and nativeOk(.search, true));
    try std.testing.expect(std.mem.indexOf(u8, block(.research, true).?, "<researchers>") != null);
    try std.testing.expect(block(.research, false) == null and !nativeOk(.research, false));
}
