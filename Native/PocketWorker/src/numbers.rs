//! Pocket's October English model can drop the hundreds in a bare integer
//! (132 became 32 in both float32/int8 and two independent transcript checks).
//! Give it an explicit cardinal pronunciation without changing displayed text.

fn cardinal(n: u32) -> String {
    const SMALL: [&str; 20] = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"];
    const TENS: [&str; 10] = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];
    if n < 20 { return SMALL[n as usize].into(); }
    if n < 100 {
        return format!("{}{}", TENS[(n / 10) as usize], if n % 10 == 0 { String::new() } else { format!(" {}", cardinal(n % 10)) });
    }
    for (scale, word) in [(1_000_000, "million"), (1_000, "thousand"), (100, "hundred")] {
        if n >= scale {
            let remainder = n % scale;
            return format!("{} {}{}", cardinal(n / scale), word, if remainder == 0 { String::new() } else { format!(" {}", cardinal(remainder)) });
        }
    }
    unreachable!()
}

pub fn prepare(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut indices = text.char_indices().peekable();
    while let Some((start, c)) = indices.next() {
        if !c.is_ascii_digit() { output.push(c); continue; }
        let mut end = start + 1;
        while let Some(&(i, next)) = indices.peek() {
            if !next.is_ascii_digit() { break; }
            end = i + 1; indices.next();
        }
        let digits = &text[start..end];
        let before = &text[..start];
        let after = &text[end..];
        let part_of_word = before.chars().next_back().is_some_and(|c| c.is_alphanumeric() || c == '_')
            || after.chars().next().is_some_and(|c| c.is_alphanumeric() || c == '_');
        let decimal_or_group = before.ends_with(['.', ','])
            || (after.starts_with(['.', ',']) && after.chars().nth(1).is_some_and(|c| c.is_ascii_digit()));
        // Salient's common reader may already have changed 1.125 to "1 point 125".
        let fraction = before.split_whitespace().next_back().is_some_and(|s| s.eq_ignore_ascii_case("point"));
        if (3..=9).contains(&digits.len()) && !digits.starts_with('0') && !part_of_word && !decimal_or_group && !fraction {
            output.push_str(&cardinal(digits.parse().unwrap()));
        } else { output.push_str(digits); }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn quantities_and_years_keep_their_exact_value() {
        assert_eq!(prepare("Sodium is 132. The year is 2026."), "Sodium is one hundred thirty two. The year is two thousand twenty six.");
        assert_eq!(prepare("120 over 80; 100, 101 and 999999999."), "one hundred twenty over 80; one hundred, one hundred one and nine hundred ninety nine million nine hundred ninety nine thousand nine hundred ninety nine.");
    }
    #[test]
    fn decimals_identifiers_grouped_numbers_and_leading_zeros_are_untouched() {
        let text = "1.125 123.45 .125 1 point 125 1,234 00132 BRCA132 Q2026 abc_132 132mg 132e3 1234567890";
        assert_eq!(prepare(text), text);
    }
    #[test]
    fn unicode_boundaries_and_original_spacing_survive() {
        assert_eq!(prepare("Na⁺: 132\n\nα132 (100)"), "Na⁺: one hundred thirty two\n\nα132 (one hundred)");
    }
}
