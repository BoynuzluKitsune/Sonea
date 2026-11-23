use lindera::{Mode, Tokenizer};
use pinyin::ToPinyin;
use std::sync::OnceLock;
use unicode_normalization::UnicodeNormalization;
use wana_kana::ConvertJapanese;

static TOKENIZER: OnceLock<Option<Tokenizer>> = OnceLock::new();

fn get_tokenizer() -> Option<&'static Tokenizer> {
    TOKENIZER
        .get_or_init(|| {
            lindera_ipadic::load_dictionary()
                .ok()
                .map(|dict| Tokenizer::new(dict, None, Mode::Normal))
        })
        .as_ref()
}

pub fn transliterate_lines(lines: Vec<String>) -> Vec<Option<String>> {
    lines.into_iter().map(|l| transliterate_text(&l)).collect()
}

pub fn transliterate_text(text: &str) -> Option<String> {
    if text.trim().is_empty() || !has_non_latin(text) {
        return None;
    }

    // Try Japanese transliteration only when Kana or Kanji/Hanzi characters are present,
    // so non-Japanese tracks (English, Turkish, Korean, Cyrillic, Greek) pay zero RAM/CPU
    // cost and never initialize the lindera IPADIC dictionary.
    if text.chars().any(|c| is_kana(c) || is_chinese_hanzi(c)) {
        if let Some(jp_res) = transliterate_japanese(text) {
            return Some(jp_res);
        }
    }

    // Fallback for Korean, Cyrillic, Greek, and Chinese Pinyin
    let mut result = String::with_capacity(text.len() * 2);

    for ch in text.chars() {
        if is_hangul(ch) {
            result.push_str(&transliterate_hangul_char(ch));
        } else if is_cyrillic(ch) {
            result.push_str(transliterate_cyrillic_char(ch));
        } else if is_greek(ch) {
            result.push_str(transliterate_greek_char(ch));
        } else if is_chinese_hanzi(ch) {
            if let Some(py) = ch.to_pinyin() {
                result.push_str(py.plain());
                result.push(' ');
            } else {
                result.push(ch);
            }
        } else {
            result.push(ch);
        }
    }

    let trimmed = result.trim().to_string();
    if trimmed == text.trim() || trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn transliterate_japanese(text: &str) -> Option<String> {
    let normalized: String = text.nfkc().collect();
    let tokenizer = get_tokenizer()?;
    let mut tokens = match tokenizer.tokenize(&normalized) {
        Ok(t) => t,
        Err(_) => return None,
    };

    let has_kana = contains_kana(&normalized);
    let has_ipadic_readings = tokens.iter_mut().any(|t| {
        t.get_details()
            .as_ref()
            .and_then(|d| d.get(7).copied())
            .is_some_and(|r| r != "*")
    });

    if !has_kana && !has_ipadic_readings {
        return None;
    }

    let mut words: Vec<(String, bool)> = Vec::new();

    for token in tokens.iter_mut() {
        let surface = token.text;
        let details = token.get_details();

        let pos = details.as_ref().and_then(|d| d.first().copied()).unwrap_or("*");
        let reading = details.as_ref().and_then(|d| d.get(7).copied());
        let pron = details.as_ref().and_then(|d| d.get(8).copied());

        let is_katakana_word = !surface.is_empty() && surface.chars().all(is_katakana);

        let romaji = if pos == "助詞" {
            match surface {
                "は" => "wa".to_string(),
                "へ" => "e".to_string(),
                "を" => "o".to_string(),
                _ => {
                    let r = pron.or(reading).unwrap_or(surface);
                    if r != "*" && !r.is_empty() {
                        r.to_romaji()
                    } else {
                        surface.to_romaji()
                    }
                }
            }
        } else if let Some(r) = pron.or(reading) {
            if r != "*" && !r.is_empty() {
                r.to_romaji()
            } else {
                surface.to_romaji()
            }
        } else {
            surface.to_romaji()
        };

        let clean_romaji = match romaji.as_str() {
            "「" | "『" | "‘" | "“" => "\"".to_string(),
            "」" | "』" | "’" | "”" => "\"".to_string(),
            "、" => ",".to_string(),
            "。" => ".".to_string(),
            "・" => " ".to_string(),
            "〜" => "~".to_string(),
            "！" => "!".to_string(),
            "？" => "?".to_string(),
            _ => romaji,
        };

        if !clean_romaji.trim().is_empty() {
            words.push((clean_romaji, is_katakana_word));
        }
    }

    let mut result = String::new();
    for (i, (word, is_kat)) in words.iter().enumerate() {
        let is_punct = matches!(word.as_str(), "," | "." | "!" | "?" | ")" | "]" | "~" | "\"");

        if i > 0 {
            let (_prev_word, prev_kat) = &words[i - 1];
            let should_join = *prev_kat && *is_kat;

            if !should_join && !is_punct && !result.ends_with('"') && !result.ends_with('(') {
                result.push(' ');
            }
        }

        result.push_str(word);
    }

    let trimmed = result.trim().to_string();
    if trimmed == text.trim() || trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn contains_kana(text: &str) -> bool {
    text.chars().any(is_kana)
}

fn has_non_latin(text: &str) -> bool {
    text.chars().any(|c| {
        is_hangul(c) || is_cyrillic(c) || is_greek(c) || is_chinese_hanzi(c) || is_kana(c)
    })
}

fn is_kana(c: char) -> bool {
    matches!(c, '\u{3040}'..='\u{309F}' | '\u{30A0}'..='\u{30FF}')
}

fn is_katakana(c: char) -> bool {
    matches!(c, '\u{30A0}'..='\u{30FF}')
}

fn is_chinese_hanzi(c: char) -> bool {
    matches!(c, '\u{4E00}'..='\u{9FFF}' | '\u{3400}'..='\u{4DBF}')
}

fn is_hangul(c: char) -> bool {
    matches!(c, '\u{AC00}'..='\u{D7A3}')
}

fn is_cyrillic(c: char) -> bool {
    matches!(c, '\u{0400}'..='\u{04FF}')
}

fn is_greek(c: char) -> bool {
    matches!(c, '\u{0370}'..='\u{03FF}')
}

fn transliterate_hangul_char(c: char) -> String {
    let code = (c as u32) - 0xAC00;
    let initial_idx = (code / 588) as usize;
    let vowel_idx = ((code % 588) / 28) as usize;
    let final_idx = (code % 28) as usize;

    const INITIALS: &[&str] = &[
        "g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h",
    ];
    const VOWELS: &[&str] = &[
        "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "weo", "we", "wi", "yu", "eu", "ui", "i",
    ];
    const FINALS: &[&str] = &[
        "", "g", "gg", "gs", "n", "nj", "nh", "d", "l", "lg", "lm", "lb", "ls", "lt", "lp", "lh", "m", "b", "bs", "s", "ss", "ng", "j", "ch", "k", "t", "p", "h",
    ];

    let init = INITIALS.get(initial_idx).copied().unwrap_or("");
    let vow = VOWELS.get(vowel_idx).copied().unwrap_or("");
    let fin = FINALS.get(final_idx).copied().unwrap_or("");

    format!("{init}{vow}{fin}")
}

fn transliterate_cyrillic_char(c: char) -> &'static str {
    match c {
        'А' => "A", 'а' => "a", 'Б' => "B", 'б' => "b", 'В' => "V", 'в' => "v",
        'Г' => "G", 'г' => "g", 'Д' => "D", 'д' => "d", 'Е' => "E", 'е' => "e",
        'Ё' => "Yo", 'ё' => "yo", 'Ж' => "Zh", 'ж' => "zh", 'З' => "Z", 'з' => "z",
        'И' => "I", 'и' => "i", 'Й' => "Y", 'й' => "y", 'К' => "K", 'к' => "k",
        'Л' => "L", 'л' => "l", 'М' => "M", 'м' => "m", 'Н' => "N", 'н' => "n",
        'О' => "O", 'о' => "o", 'П' => "P", 'п' => "p", 'Р' => "R", 'р' => "r",
        'С' => "S", 'с' => "s", 'Т' => "T", 'т' => "t", 'У' => "U", 'у' => "u",
        'Ф' => "F", 'ф' => "f", 'Х' => "Kh", 'х' => "kh", 'Ц' => "Ts", 'ц' => "ts",
        'Ч' => "Ch", 'ч' => "ch", 'Ш' => "Sh", 'ш' => "sh", 'Щ' => "Shch", 'щ' => "shch",
        'Ъ' | 'ъ' | 'Ь' | 'ь' => "", 'Ы' => "Y", 'ы' => "y", 'Э' => "E", 'э' => "e",
        'Ю' => "Yu", 'ю' => "yu", 'Я' => "Ya", 'я' => "ya",
        _ => "",
    }
}

fn transliterate_greek_char(c: char) -> &'static str {
    match c {
        'Α' | 'Ά' => "A", 'α' | 'ά' => "a",
        'Β' => "V", 'β' => "v",
        'Γ' => "G", 'γ' => "g",
        'Δ' => "D", 'δ' => "d",
        'Ε' | 'Έ' => "E", 'ε' | 'έ' => "e",
        'Ζ' => "Z", 'ζ' => "z",
        'Η' | 'Ή' => "I", 'η' | 'ή' => "i",
        'Θ' => "Th", 'θ' => "th", 'Ι' | 'Ί' | 'Ϊ' => "I", 'ι' | 'ί' | 'ϊ' | 'ΐ' => "i",
        'Κ' => "K", 'κ' => "k",
        'Λ' => "L", 'λ' => "l", 'Μ' => "M", 'μ' => "m",
        'Ν' => "N", 'ν' => "n", 'Ξ' => "X", 'ξ' => "x",
        'Ο' | 'Ό' => "O", 'ο' | 'ό' => "o",
        'Π' => "P", 'π' => "p", 'Ρ' => "R", 'ρ' => "r",
        'Σ' | 'Ϲ' => "S", 'σ' | 'ς' => "s", 'Τ' => "T", 'τ' => "t", 'Υ' | 'Ύ' | 'Ϋ' => "Y", 'υ' | 'ύ' | 'ϋ' | 'ΰ' => "y",
        'Φ' => "F", 'φ' => "f", 'Χ' => "Ch", 'χ' => "ch",
        'Ψ' => "Ps", 'ψ' => "ps", 'Ω' | 'Ώ' => "O", 'ω' | 'ώ' => "o",
        _ => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_transliterate_japanese_kana() {
        assert_eq!(transliterate_text("さくら"), Some("sakura".to_string()));
        assert_eq!(transliterate_text("ヒトリエ"), Some("hitorie".to_string()));
        assert_eq!(transliterate_text("きっと"), Some("kitto".to_string()));
    }

    #[test]
    fn test_transliterate_japanese_kanji_kana() {
        assert_eq!(
            transliterate_text("私は音楽を聴く"),
            Some("watashi wa ongaku o kiku".to_string())
        );
        assert_eq!(
            transliterate_text("君の名は。"),
            Some("kimi no na wa.".to_string())
        );
        assert_eq!(
            transliterate_text("「夢」"),
            Some("\"yume\"".to_string())
        );
        assert_eq!(
            transliterate_text("あっ！"),
            Some("a!".to_string())
        );
        assert_eq!(
            transliterate_text("東京の夜"),
            Some("tookyoo no yoru".to_string())
        );
    }

    #[test]
    fn test_transliterate_korean_hangul() {
        assert_eq!(transliterate_text("안녕"), Some("annyeong".to_string()));
    }

    #[test]
    fn test_transliterate_cyrillic() {
        assert_eq!(transliterate_text("Привет"), Some("Privet".to_string()));
    }

    #[test]
    fn test_transliterate_pure_latin_returns_none() {
        assert_eq!(transliterate_text("Hello World 123"), None);
    }
}
