import Foundation
import MLX
import MLXLMCommon

// Speculative decoding that works with Qwen 3.5's recurrent layers (which can't be rewound, so Apple's draft-model
// path refuses them). Each round:
//   1. the small draft writes k words ahead
//   2. the big brain reads all of them in ONE pass (one trip to the SSD for experts) and picks its own word at each spot
//   3. words where both agree are kept, plus the brain's own next word
//   4. on a disagreement the brain restores its saved state and re-reads only the agreed words
// The brain's own pick decides every word, so the text is what it would write alone.

public struct SpecStats: Sendable {
    public var rounds = 0, drafted = 0, accepted = 0, mainPasses = 0, generated = 0
    public var acceptRate: Double { drafted == 0 ? 0 : Double(accepted) / Double(drafted) }
    public var wordsPerPass: Double { mainPasses == 0 ? 0 : Double(generated) / Double(mainPasses) }
}

enum Speculator {
    static func pick(_ logits: MLXArray, temperature: Float) -> [Int] {
        // logits: [n, vocab] → one pick per row
        if temperature <= 0 { return argMax(logits, axis: -1).asArray(Int32.self).map { Int($0) } }
        return MLXRandom.categorical(logits.asType(.float32) / temperature, axis: -1).asArray(Int32.self).map { Int($0) }
    }

    /// Runs main+draft from a state where both caches hold the prompt minus its last token `first`.
    static func run(main: any LanguageModel, draft: any LanguageModel, mainCache: [KVCache], draftCache: [KVCache],
                    first: Int, k: Int, maxTokens: Int, temperature: Float, stop: Set<Int>,
                    emit: (Int) -> Bool) -> SpecStats {
        var st = SpecStats()
        var mainCache = mainCache, draftCache = draftCache
        var y = first
        var draftPending: [Int] = [y]          // tokens the draft still has to read before it can guess
        func forward(_ m: any LanguageModel, _ toks: [Int], _ cache: [KVCache]) -> MLXArray {
            let out = m(MLXArray(toks.map { Int32($0) })[.newAxis], cache: cache)   // [1, n, vocab]
            eval(out); return out[0]
        }
        func copy(_ c: [KVCache]) -> [KVCache] { c.map { $0.copy() } }

        while st.generated < maxTokens {
            st.rounds += 1
            // 1) draft k words (remember the draft's state first, to rewind on disagreement)
            let draftSaved = copy(draftCache)
            var guesses: [Int] = []
            var lg = forward(draft, draftPending, draftCache)
            for i in 0..<k {
                let g = pick(lg[(lg.dim(0) - 1)...], temperature: temperature)[0]
                guesses.append(g)
                if stop.contains(g) || i == k - 1 { break }
                lg = forward(draft, [g], draftCache)
            }
            st.drafted += guesses.count

            // 2) the brain checks y + all guesses in one pass
            let mainSaved = copy(mainCache)
            let logits = forward(main, [y] + guesses, mainCache)
            st.mainPasses += 1
            let mine = pick(logits, temperature: temperature)          // brain's own word at every spot
            var n = 0
            while n < guesses.count && mine[n] == guesses[n] { n += 1 }
            st.accepted += n
            let keep = Array(mine[0...n])                              // agreed words + the brain's next word

            // 3) on disagreement: rewind and re-read only what was agreed (y + the n accepted guesses)
            if n < guesses.count {
                mainCache = mainSaved
                _ = forward(main, [y] + Array(guesses[..<n]), mainCache)
                st.mainPasses += 1
            }
            // the draft read its pending words + guesses[..<c-1]; keep that if it's all agreed, else rewind it
            let c = guesses.count
            let newY = keep.last!
            if n >= c - 1 {
                draftPending = Array(guesses[(c - 1)..<n]) + [newY]
            } else {
                draftCache = draftSaved
                draftPending = draftPending + Array(guesses[..<n]) + [newY]
            }

            // 4) hand out the words
            for t in keep {
                st.generated += 1
                if stop.contains(t) || !emit(t) || st.generated >= maxTokens { return st }
            }
            y = newY
        }
        return st
    }
}
