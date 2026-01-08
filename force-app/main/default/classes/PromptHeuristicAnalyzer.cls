/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * PromptHeuristicAnalyzer performs heuristic-based analysis of user prompts to detect
 * jailbreak attempts and prompt injection attacks. This is Layer 2 of the multi-layered
 * Prompt Safety detection system.
 *
 * Heuristics implemented:
 * - Instruction Override: Detects "ignore previous", "new instructions", etc.
 * - Role Manipulation: Detects persona changes, "you are now", "act as"
 * - Delimiter Injection: Detects system prompt markers, boundary violations
 * - Repetition Attack: Detects token stuffing and excessive repetition
 * - Unicode Abuse: Detects homoglyphs, invisible characters, RTL override
 * - Excessive Instructions: Detects unusually high imperative verb density
 *
 * Unlike pattern-based detection, heuristics analyze the semantic and structural
 * characteristics of the text to detect novel attack variations.
 *
 * Part of the Prompt Safety Trust Layer for AI safety.
 *
 * @example
 * PromptHeuristicAnalyzer analyzer = new PromptHeuristicAnalyzer();
 * PromptHeuristicAnalyzer.AnalysisResult result = analyzer.analyze(userMessage);
 * Decimal threatScore = result.aggregatedScore;
 */
public inherited sharing class PromptHeuristicAnalyzer {
    // Logging prefix
    private static final String LOG_PREFIX = '[PromptHeuristicAnalyzer] ';

    // Heuristic weights (configurable)
    private static final Decimal WEIGHT_INSTRUCTION_OVERRIDE = 0.4;
    private static final Decimal WEIGHT_ROLE_MANIPULATION = 0.4;
    private static final Decimal WEIGHT_DELIMITER_INJECTION = 0.5;
    private static final Decimal WEIGHT_REPETITION_ATTACK = 0.3;
    private static final Decimal WEIGHT_UNICODE_ABUSE = 0.3;
    private static final Decimal WEIGHT_EXCESSIVE_INSTRUCTIONS = 0.2;

    /**
     * @description Result of heuristic analysis containing individual scores and indicators.
     */
    public class AnalysisResult {
        public Decimal aggregatedScore { get; set; }
        public Map<String, Decimal> heuristicScores { get; set; }
        public List<ThreatAssessment.ThreatIndicator> indicators { get; set; }

        public AnalysisResult() {
            this.aggregatedScore = 0.0;
            this.heuristicScores = new Map<String, Decimal>();
            this.indicators = new List<ThreatAssessment.ThreatIndicator>();
        }
    }

    /**
     * @description Creates a new heuristic analyzer with default settings.
     */
    public PromptHeuristicAnalyzer() {
        // Default constructor
    }

    /**
     * @description Analyzes text using all heuristics and returns aggregated result.
     *
     * @param text The text to analyze
     * @return AnalysisResult containing scores and indicators
     */
    public AnalysisResult analyze(String text) {
        AnalysisResult result = new AnalysisResult();

        if (String.isBlank(text)) {
            return result;
        }

        String lowerText = text.toLowerCase();

        // Run each heuristic
        Decimal instructionScore = analyzeInstructionOverride(lowerText, result.indicators);
        result.heuristicScores.put('InstructionOverride', instructionScore);

        Decimal roleScore = analyzeRoleManipulation(lowerText, result.indicators);
        result.heuristicScores.put('RoleManipulation', roleScore);

        Decimal delimiterScore = analyzeDelimiterInjection(text, result.indicators);
        result.heuristicScores.put('DelimiterInjection', delimiterScore);

        Decimal repetitionScore = analyzeRepetitionAttack(text, result.indicators);
        result.heuristicScores.put('RepetitionAttack', repetitionScore);

        Decimal unicodeScore = analyzeUnicodeAbuse(text, result.indicators);
        result.heuristicScores.put('UnicodeAbuse', unicodeScore);

        Decimal instructionDensityScore = analyzeExcessiveInstructions(lowerText, result.indicators);
        result.heuristicScores.put('ExcessiveInstructions', instructionDensityScore);

        // Calculate weighted aggregate score
        result.aggregatedScore = calculateAggregatedScore(instructionScore, roleScore, delimiterScore, repetitionScore, unicodeScore, instructionDensityScore);

        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Analysis complete. Score: ' + result.aggregatedScore + ', Indicators: ' + result.indicators.size());

        return result;
    }

    // =========================================================================
    // HEURISTIC ANALYZERS
    // =========================================================================

    /**
     * @description Analyzes for instruction override attempts.
     * Detects phrases like "ignore previous", "disregard", "new instructions".
     */
    private Decimal analyzeInstructionOverride(String lowerText, List<ThreatAssessment.ThreatIndicator> indicators) {
        List<String> overrideIndicators = new List<String>{
            'ignore previous',
            'ignore all previous',
            'ignore your previous',
            'disregard previous',
            'disregard your previous',
            'disregard all',
            'forget your instructions',
            'forget all instructions',
            'forget everything',
            'new instructions',
            'your new instructions',
            'follow these instructions instead',
            'override your',
            'override all',
            'override instructions',
            'from now on you',
            'from this point',
            'starting now',
            'your new role',
            'your real purpose',
            'your true purpose',
            'stop being',
            'stop acting as',
            'you no longer',
            'do not follow',
            'don\'t follow your'
        };

        Integer matchCount = 0;
        for (String indicator : overrideIndicators) {
            if (lowerText.contains(indicator)) {
                matchCount++;
                indicators.add(
                    new ThreatAssessment.ThreatIndicator(
                        'Heuristic',
                        'InstructionOverride',
                        'InstructionOverride_' + indicator.replace(' ', '_'),
                        'Detected instruction override attempt: "' + indicator + '"',
                        0.3
                    )
                );
            }
        }

        // Normalize score based on matches (each match adds 0.25, capped at 1.0)
        return Math.min(1.0, matchCount * 0.25);
    }

    /**
     * @description Analyzes for role manipulation attempts.
     * Detects persona changes like "you are now", "act as", "pretend to be".
     */
    private Decimal analyzeRoleManipulation(String lowerText, List<ThreatAssessment.ThreatIndicator> indicators) {
        List<String> roleIndicators = new List<String>{
            'you are now',
            'you\'re now',
            'from now on you are',
            'pretend to be',
            'pretend you are',
            'pretend that you',
            'act as',
            'act like',
            'behave as',
            'behave like',
            'roleplay as',
            'role play as',
            'play the role of',
            'imagine you are',
            'imagine that you',
            'imagine being',
            'take on the role',
            'assume the role',
            'assume the identity',
            'you are dan',
            'you are jailbroken',
            'you are unrestricted',
            'you have no rules',
            'you have no restrictions',
            'you have no limits',
            'you can do anything',
            'you are capable of anything',
            'developer mode',
            'enable developer',
            'sudo mode',
            'my grandmother',
            'my grandma',
            'tell me a story about' // Grandma exploit variations
        };

        Integer matchCount = 0;
        for (String indicator : roleIndicators) {
            if (lowerText.contains(indicator)) {
                matchCount++;
                indicators.add(
                    new ThreatAssessment.ThreatIndicator(
                        'Heuristic',
                        'RoleManipulation',
                        'RoleManipulation_' + indicator.replace(' ', '_').left(30),
                        'Detected role manipulation attempt: "' + indicator + '"',
                        0.35
                    )
                );
            }
        }

        return Math.min(1.0, matchCount * 0.25);
    }

    /**
     * @description Analyzes for delimiter injection attacks.
     * Detects system prompt markers and boundary violations.
     */
    private Decimal analyzeDelimiterInjection(String text, List<ThreatAssessment.ThreatIndicator> indicators) {
        // Case-sensitive patterns for delimiter injection
        List<String> delimiterPatterns = new List<String>{
            '### System',
            '###System',
            '### SYSTEM',
            '###SYSTEM',
            '[INST]',
            '[/INST]',
            '<<SYS>>',
            '<</SYS>>',
            '<|system|>',
            '<|user|>',
            '<|assistant|>',
            '</s>',
            '<s>',
            '[S]',
            '[/S]',
            '```system',
            '```SYSTEM',
            '---BEGIN SYSTEM---',
            '---END SYSTEM---',
            'SYSTEM:',
            'System:',
            'USER:',
            'ASSISTANT:',
            '\\n### ',
            '\\nSystem:',
            '\\nUSER:',
            '<|im_start|>',
            '<|im_end|>',
            '[System]',
            '[User]',
            '[Assistant]'
        };

        Integer matchCount = 0;
        for (String delimiter : delimiterPatterns) {
            if (text.contains(delimiter)) {
                matchCount++;
                indicators.add(
                    new ThreatAssessment.ThreatIndicator(
                        'Heuristic',
                        'DelimiterInjection',
                        'DelimiterInjection_detected',
                        'Detected delimiter injection: "' + delimiter.left(20) + '"',
                        0.5
                    )
                );
            }
        }

        return Math.min(1.0, matchCount * 0.35);
    }

    /**
     * @description Analyzes for repetition attacks (token stuffing).
     * Detects excessive repetition of words or phrases.
     */
    private Decimal analyzeRepetitionAttack(String text, List<ThreatAssessment.ThreatIndicator> indicators) {
        if (String.isBlank(text) || text.length() < 50) {
            return 0.0;
        }

        Decimal score = 0.0;

        // Check for repeated words
        List<String> words = text.toLowerCase().split('\\s+');
        Map<String, Integer> wordCounts = new Map<String, Integer>();

        for (String word : words) {
            if (word.length() > 2) {
                // Ignore very short words
                Integer count = wordCounts.get(word);
                wordCounts.put(word, (count == null ? 0 : count) + 1);
            }
        }

        // Check for abnormally high frequency words
        for (String word : wordCounts.keySet()) {
            Integer count = wordCounts.get(word);
            Decimal frequency = (Decimal) count / words.size();

            // If a non-common word appears more than 15% of total words, flag it
            if (frequency > 0.15 && count > 5 && !isCommonWord(word)) {
                score += 0.2;
                indicators.add(
                    new ThreatAssessment.ThreatIndicator(
                        'Heuristic',
                        'RepetitionAttack',
                        'WordRepetition_' + word.left(20),
                        'Excessive repetition of word: "' + word + '" (' + count + ' times)',
                        0.25
                    )
                );
            }
        }

        // Check for repeated character sequences (e.g., "AAAAAAA")
        System.Pattern repeatedChars = System.Pattern.compile('(.)\\1{10,}');
        System.Matcher m = repeatedChars.matcher(text);
        if (m.find()) {
            score += 0.3;
            indicators.add(
                new ThreatAssessment.ThreatIndicator('Heuristic', 'RepetitionAttack', 'CharacterRepetition', 'Detected excessive character repetition', 0.3)
            );
        }

        return Math.min(1.0, score);
    }

    /**
     * @description Analyzes for Unicode abuse attacks.
     * Detects homoglyphs, invisible characters, and RTL override.
     */
    private Decimal analyzeUnicodeAbuse(String text, List<ThreatAssessment.ThreatIndicator> indicators) {
        if (String.isBlank(text)) {
            return 0.0;
        }

        Decimal score = 0.0;

        // Check for zero-width characters
        if (text.contains('\u200B') || text.contains('\u200C') || text.contains('\u200D') || text.contains('\uFEFF') || text.contains('\u2060')) {
            score += 0.4;
            indicators.add(
                new ThreatAssessment.ThreatIndicator(
                    'Heuristic',
                    'UnicodeAbuse',
                    'ZeroWidthCharacters',
                    'Detected zero-width or invisible Unicode characters',
                    0.4
                )
            );
        }

        // Check for RTL override characters (used to reverse text display)
        if (text.contains('\u202E') || text.contains('\u202D') || text.contains('\u202A') || text.contains('\u202B')) {
            score += 0.5;
            indicators.add(
                new ThreatAssessment.ThreatIndicator(
                    'Heuristic',
                    'UnicodeAbuse',
                    'RTLOverride',
                    'Detected RTL override characters (potential text direction attack)',
                    0.5
                )
            );
        }

        // Check for high concentration of non-ASCII characters in otherwise ASCII text
        Integer asciiCount = 0;
        Integer nonAsciiCount = 0;
        for (Integer i = 0; i < text.length() && i < 1000; i++) {
            Integer charCode = text.charAt(i);
            if (charCode >= 32 && charCode <= 126) {
                asciiCount++;
            } else if (charCode > 127) {
                nonAsciiCount++;
            }
        }

        // If text is mostly ASCII but has suspicious non-ASCII (potential homoglyphs)
        if (asciiCount > 0 && nonAsciiCount > 0) {
            Decimal nonAsciiRatio = (Decimal) nonAsciiCount / (asciiCount + nonAsciiCount);
            if (nonAsciiRatio > 0.05 && nonAsciiRatio < 0.3) {
                // Suspicious: small but significant non-ASCII in mostly ASCII text
                score += 0.2;
                indicators.add(
                    new ThreatAssessment.ThreatIndicator(
                        'Heuristic',
                        'UnicodeAbuse',
                        'SuspiciousNonASCII',
                        'Detected suspicious non-ASCII characters mixed with ASCII (potential homoglyphs)',
                        0.2
                    )
                );
            }
        }

        return Math.min(1.0, score);
    }

    /**
     * @description Analyzes for excessive instruction density.
     * Detects unusually high number of imperative verbs.
     */
    private Decimal analyzeExcessiveInstructions(String lowerText, List<ThreatAssessment.ThreatIndicator> indicators) {
        if (String.isBlank(lowerText) || lowerText.length() < 20) {
            return 0.0;
        }

        // Count imperative verbs at start of sentences/clauses
        List<String> imperativeIndicators = new List<String>{
            'do ',
            'don\'t ',
            'never ',
            'always ',
            'must ',
            'should ',
            'will ',
            'shall ',
            'make sure',
            'ensure ',
            'remember ',
            'output ',
            'generate ',
            'write ',
            'create ',
            'produce ',
            'respond ',
            'answer ',
            'reply ',
            'say ',
            'tell ',
            'execute ',
            'run ',
            'perform ',
            'complete '
        };

        Integer instructionCount = 0;
        for (String indicator : imperativeIndicators) {
            // Count occurrences
            Integer idx = 0;
            while ((idx = lowerText.indexOf(indicator, idx)) != -1) {
                instructionCount++;
                idx += indicator.length();
            }
        }

        // Calculate instruction density (instructions per 100 characters)
        Decimal density = (Decimal) instructionCount / (lowerText.length() / 100.0);

        // High density (more than 3 per 100 chars) is suspicious
        if (density > 3.0) {
            Decimal score = Math.min(1.0, (density - 3.0) * 0.2);
            if (score > 0.1) {
                indicators.add(
                    new ThreatAssessment.ThreatIndicator(
                        'Heuristic',
                        'ExcessiveInstructions',
                        'HighImperativeDensity',
                        'Detected high density of imperative instructions (' + density.setScale(1) + ' per 100 chars)',
                        score
                    )
                );
            }
            return score;
        }

        return 0.0;
    }

    // =========================================================================
    // HELPER METHODS
    // =========================================================================

    /**
     * @description Calculates the weighted aggregate score from individual heuristics.
     */
    private Decimal calculateAggregatedScore(
        Decimal instructionScore,
        Decimal roleScore,
        Decimal delimiterScore,
        Decimal repetitionScore,
        Decimal unicodeScore,
        Decimal instructionDensityScore
    ) {
        // Weighted combination with diminishing returns
        Decimal weightedSum =
            instructionScore * WEIGHT_INSTRUCTION_OVERRIDE +
            roleScore * WEIGHT_ROLE_MANIPULATION +
            delimiterScore * WEIGHT_DELIMITER_INJECTION +
            repetitionScore * WEIGHT_REPETITION_ATTACK +
            unicodeScore * WEIGHT_UNICODE_ABUSE +
            instructionDensityScore * WEIGHT_EXCESSIVE_INSTRUCTIONS;

        Decimal totalWeight =
            WEIGHT_INSTRUCTION_OVERRIDE +
            WEIGHT_ROLE_MANIPULATION +
            WEIGHT_DELIMITER_INJECTION +
            WEIGHT_REPETITION_ATTACK +
            WEIGHT_UNICODE_ABUSE +
            WEIGHT_EXCESSIVE_INSTRUCTIONS;

        // Normalize to 0-1 range
        Decimal normalizedScore = weightedSum / totalWeight;

        // Apply sigmoid-like curve to boost high scores
        // This makes the score more decisive (closer to 0 or 1)
        if (normalizedScore > 0.3) {
            normalizedScore = normalizedScore + (normalizedScore - 0.3) * 0.5;
        }

        return Math.min(1.0, normalizedScore);
    }

    /**
     * @description Checks if a word is a common English word (to avoid false positives).
     */
    private Boolean isCommonWord(String word) {
        Set<String> commonWords = new Set<String>{
            'the',
            'be',
            'to',
            'of',
            'and',
            'a',
            'in',
            'that',
            'have',
            'i',
            'it',
            'for',
            'not',
            'on',
            'with',
            'he',
            'as',
            'you',
            'do',
            'at',
            'this',
            'but',
            'his',
            'by',
            'from',
            'they',
            'we',
            'say',
            'her',
            'she',
            'or',
            'an',
            'will',
            'my',
            'one',
            'all',
            'would',
            'there',
            'their',
            'what',
            'so',
            'up',
            'out',
            'if',
            'about',
            'who',
            'get',
            'which',
            'go',
            'me',
            'is',
            'are',
            'was',
            'were',
            'been',
            'being',
            'has',
            'had',
            'does',
            'did',
            'can',
            'could',
            'should',
            'would',
            'may',
            'might',
            'must',
            'shall'
        };
        return commonWords.contains(word.toLowerCase());
    }
}
