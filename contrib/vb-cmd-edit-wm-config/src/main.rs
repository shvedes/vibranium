use std::fs;
use std::process;

// ─── CLI parsing ─────────────────────────────────────────────────────────────

struct Args {
    path: String,
    file: String,
}

fn parse_args() -> Args {
    let raw: Vec<String> = std::env::args().collect();

    if raw.len() < 3 {
        eprintln!("Usage: vb-cmd-edit-wm-config <path:value> <file>");
        process::exit(1);
    }

    Args {
        path: raw[1].clone(),
        file: raw[2].clone(),
    }
}

// ─── Path parsing ─────────────────────────────────────────────────────────────
// "section:subsection:option:value@-2"  →  (parts, occurrence)

fn parse_path(path: &str) -> (Vec<String>, i32) {
    let mut parts: Vec<String> = path.split(':').map(str::to_string).collect();
    let mut occurrence = 1i32;

    if let Some(last) = parts.last_mut() {
        if let Some(at_pos) = last.rfind('@') {
            let index_str = last[at_pos + 1..].to_string();
            if let Ok(n) = index_str.parse::<i32>() {
                occurrence = n;
                *last = last[..at_pos].to_string();
            }
        }
    }

    (parts, occurrence)
}

// ─── Indent detection ─────────────────────────────────────────────────────────

fn detect_indent_unit(lines: &[String]) -> String {
    let mut min_indent: Option<String> = None;
    for line in lines {
        let stripped = line.trim_start();
        if stripped.is_empty() || stripped.starts_with('#') || stripped == line.as_str() {
            continue;
        }
        let leading = &line[..line.len() - stripped.len()];
        if !leading.is_empty() {
            match &min_indent {
                None => min_indent = Some(leading.to_string()),
                Some(m) if leading.len() < m.len() => {
                    min_indent = Some(leading.to_string())
                }
                _ => {}
            }
        }
    }
    min_indent.unwrap_or_else(|| "\t".to_string())
}

fn get_indent(level: usize, unit: &str) -> String {
    unit.repeat(level)
}

// ─── Section finding ──────────────────────────────────────────────────────────
// Returns (start_line, end_line, nesting_depth)

fn find_all_section_bounds(
    lines: &[String],
    path: &[String],
    start_line: usize,
) -> Vec<(usize, usize, usize)> {
    let mut results = Vec::new();
    let mut current_path: Vec<String> = Vec::new();
    let mut i = start_line;

    while i < lines.len() {
        let stripped = lines[i].trim_start();

        if stripped.is_empty() || stripped.starts_with('#') {
            i += 1;
            continue;
        }

        if stripped.starts_with('}') {
            current_path.pop();
            i += 1;
            continue;
        }

        // Section opening: `word {` or `word-with-dashes {`
        if let Some(name) = section_name(stripped) {
            current_path.push(name);

            if current_path == path {
                let depth = current_path.len() - 1;
                let mut brace_depth = 1i32;
                let mut j = i + 1;
                while j < lines.len() && brace_depth > 0 {
                    let s = lines[j].trim_start();
                    if !s.starts_with('#') {
                        brace_depth += s.chars().filter(|&c| c == '{').count() as i32;
                        brace_depth -= s.chars().filter(|&c| c == '}').count() as i32;
                    }
                    j += 1;
                }
                results.push((i, j - 1, depth));
                current_path.pop();
                i = j;
                continue;
            }
        }

        i += 1;
    }

    results
}

/// Returns None if not found, otherwise (start, end, depth).
/// `occurrence`: 1-indexed positive or negative-from-end.
fn find_section_bounds(
    lines: &[String],
    path: &[String],
    start_line: usize,
    occurrence: i32,
) -> Option<(usize, usize, usize)> {
    let all = find_all_section_bounds(lines, path, start_line);
    if all.is_empty() {
        return None;
    }
    let idx = if occurrence > 0 {
        (occurrence as usize).checked_sub(1)?
    } else {
        let from_end = (-occurrence) as usize;
        all.len().checked_sub(from_end)?
    };
    all.get(idx).copied()
}

/// Match `word {` or `word-with-dashes {` at start of stripped line.
fn section_name(stripped: &str) -> Option<String> {
    let mut chars = stripped.chars().peekable();
    let mut name = String::new();
    while let Some(&c) = chars.peek() {
        if c.is_alphanumeric() || c == '-' || c == '_' {
            name.push(c);
            chars.next();
        } else {
            break;
        }
    }
    if name.is_empty() {
        return None;
    }
    // Skip whitespace
    while chars.peek() == Some(&' ') || chars.peek() == Some(&'\t') {
        chars.next();
    }
    if chars.peek() == Some(&'{') {
        Some(name)
    } else {
        None
    }
}

// ─── Option finding ───────────────────────────────────────────────────────────

fn find_option_in_section(
    lines: &[String],
    section_start: usize,
    section_end: usize,
    option_name: &str,
) -> Option<usize> {
    let mut depth = 0i32;
    for i in (section_start + 1)..section_end {
        let stripped = lines[i].trim_start();
        if stripped.is_empty() || stripped.starts_with('#') {
            continue;
        }
        if stripped.contains('{') {
            depth += stripped.chars().filter(|&c| c == '{').count() as i32;
            continue;
        }
        if stripped.contains('}') {
            depth -= stripped.chars().filter(|&c| c == '}').count() as i32;
            continue;
        }
        if depth > 0 {
            continue;
        }
        if let Some(name) = option_key(stripped) {
            if name == option_name {
                return Some(i);
            }
        }
    }
    None
}

/// Extract key from `key = value` line.
fn option_key(stripped: &str) -> Option<String> {
    if let Some(eq) = stripped.find('=') {
        let key = stripped[..eq].trim().to_string();
        if key.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_') && !key.is_empty() {
            return Some(key);
        }
    }
    None
}


// ─── Write ────────────────────────────────────────────────────────────────────

fn write_value(lines: &mut Vec<String>, path: &[String], value: &str, file_path: &str, occurrence: i32) {
    // Strip surrounding quotes
    let value = strip_quotes(value);
    if value.is_empty() {
        process::exit(1);
    }

    let unit = detect_indent_unit(lines);
    let (section_path, option_tail) = path.split_at(path.len() - 1);
    let option_name = &option_tail[0];

    // ── Top-level option ──
    if section_path.is_empty() {
        for i in 0..lines.len() {
            let stripped = lines[i].trim_start().to_string();
            if stripped.is_empty() || stripped.starts_with('#') {
                continue;
            }
            if let Some(key) = option_key(&stripped) {
                if key == *option_name {
                    lines[i] = format!("{} = {}\n", option_name, value);
                    write_file(file_path, lines);
                    return;
                }
            }
        }
        lines.insert(0, format!("{} = {}\n", option_name, value));
        write_file(file_path, lines);
        return;
    }

    // ── Navigate sections, create if missing ──
    let mut current_line = 0usize;

    for depth in 0..section_path.len() {
        let sub = &section_path[..depth + 1];
        let occ = if depth < section_path.len() - 1 { 1 } else { occurrence };
        let bounds = find_section_bounds(lines, sub, current_line, occ);

        if let Some((start, _, _)) = bounds {
            current_line = start;

            // If this is the innermost section, handle the option
            if depth == section_path.len() - 1 {

                let sec_bounds = find_section_bounds(lines, section_path, 0, occurrence)
                    .unwrap_or_else(|| process::exit(1));
                let (sec_start, sec_end, bd) = sec_bounds;
                let opt_indent = get_indent(bd + 1, &unit);

                if let Some(opt_line) =
                    find_option_in_section(lines, sec_start, sec_end, option_name)
                {
                    lines[opt_line] = format!("{}{} = {}\n", opt_indent, option_name, value);
                } else {
                    lines.insert(sec_end, format!("{}{} = {}\n", opt_indent, option_name, value));
                }
                write_file(file_path, lines);
                return;
            }
        } else {
            // Create missing section(s) + option
            let (insert_pos, base_depth) = if depth == 0 {
                (lines.len(), 0usize)
            } else {
                match find_section_bounds(lines, &section_path[..depth], 0, 1) {
                    Some((_, parent_end, parent_depth)) => (parent_end, parent_depth + 1),
                    None => (lines.len(), depth),
                }
            };

            let mut to_insert: Vec<String> = Vec::new();

            // Blank line before new section if previous line is `}`
            if insert_pos > 0
                && insert_pos <= lines.len()
                && lines[insert_pos - 1].trim() == "}"
            {
                to_insert.push("\n".to_string());
            }

            for i in depth..section_path.len() {
                let ind = get_indent(base_depth + (i - depth), &unit);
                to_insert.push(format!("{}{} {{\n", ind, section_path[i]));
            }

            let opt_ind = get_indent(base_depth + (section_path.len() - depth), &unit);
            to_insert.push(format!("{}{} = {}\n", opt_ind, option_name, value));

            for i in (0..=(section_path.len() - depth - 1)).rev() {
                let ind = get_indent(base_depth + i, &unit);
                to_insert.push(format!("{}}}\n", ind));
            }

            for line in to_insert.into_iter().rev() {
                lines.insert(insert_pos, line);
            }

            write_file(file_path, lines);
            return;
        }
    }
}

fn strip_quotes(s: &str) -> &str {
    if (s.starts_with('"') && s.ends_with('"')) || (s.starts_with('\'') && s.ends_with('\'')) {
        if s == "\"\"" || s == "''" {
            return "";
        }
        return &s[1..s.len() - 1];
    }
    s
}

fn write_file(path: &str, lines: &[String]) {
    let content: String = lines.concat();
    fs::write(path, content).unwrap_or_else(|e| {
        eprintln!("Error writing {}: {}", path, e);
        process::exit(1);
    });
}

// ─── Main ─────────────────────────────────────────────────────────────────────

fn main() {
    let args = parse_args();

    let lines: Vec<String> = match fs::read_to_string(&args.file) {
        Ok(content) => content.lines().map(|l| format!("{}\n", l)).collect(),
        Err(_) => Vec::new(),
    };

    let (path_and_value, occurrence) = parse_path(&args.path);

    if path_and_value.len() < 2 {
        process::exit(1);
    }
    let path = &path_and_value[..path_and_value.len() - 1];
    let value = &path_and_value[path_and_value.len() - 1];
    let mut lines = lines;
    write_value(&mut lines, path, value, &args.file, occurrence);
}
