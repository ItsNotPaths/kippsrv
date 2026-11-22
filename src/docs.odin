// The docs, built in, so they come with the binary and need no files installed.
//
// HOWTO.md carries its own word index: a line `<!-- howto: word word -->`
// opens a snippet that runs to the next marker or heading.
package kippsrv

import "core:fmt"
import "core:slice"
import "core:strings"

README :: #load("../README.md", string)
HOWTO  :: #load("../HOWTO.md", string)

@(private = "file")
MARKER :: "<!-- howto: "

Snippet :: struct {
	heading: string,     // "4. Write a source file > Claims"
	words:   []string,
	text:    string,
}

// HOWTO as a reader sees it: without the markers.
howto_text :: proc() -> string {
	builder := strings.builder_make(context.temp_allocator)
	text := HOWTO
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, MARKER) do continue
		strings.write_string(&builder, line)
		strings.write_byte(&builder, '\n')
	}
	return strings.to_string(builder)
}

howto_snippets :: proc() -> []Snippet {
	lines := strings.split_lines(HOWTO, context.temp_allocator)
	snippets := make([dynamic]Snippet, context.temp_allocator)
	section, subsection: string
	open := false
	first := 0
	in_code := false

	for line, index in lines {
		if strings.has_prefix(line, "```") do in_code = !in_code
		if in_code do continue
		marker := strings.has_prefix(line, MARKER)
		heading := strings.has_prefix(line, "#")
		if !marker && !heading do continue

		if open do snippets[len(snippets) - 1].text = strings.trim_space(strings.join(lines[first:index], "\n", context.temp_allocator))
		open = false

		switch {
		case strings.has_prefix(line, "### "):
			subsection = line[4:]
		case strings.has_prefix(line, "## "):
			section, subsection = line[3:], ""
		case marker:
			words := strings.trim_suffix(line[len(MARKER):], " -->")
			heading_path := section if subsection == "" else fmt.tprintf("%s > %s", section, subsection)
			append(&snippets, Snippet{heading = heading_path, words = strings.fields(words, context.temp_allocator)})
			open, first = true, index + 1
		}
	}
	if open do snippets[len(snippets) - 1].text = strings.trim_space(strings.join(lines[first:], "\n", context.temp_allocator))
	return snippets[:]
}

// The snippets that best answer the query. A word in a snippet's index counts
// twice, a prefix of one (three letters or more) once. When no index word
// matches, the snippets whose text holds the most query words answer.
howto_find :: proc(query: []string) -> []Snippet {
	snippets := howto_snippets()
	scores := make([]int, len(snippets), context.temp_allocator)
	terms := make([dynamic]string, context.temp_allocator)
	for word in query {
		term := strings.to_lower(strings.trim(word, ".,:;?!\"'`()"), context.temp_allocator)
		if term != "" do append(&terms, term)
	}

	for snippet, index in snippets {
		for term in terms {
			if slice.contains(snippet.words, term) {
				scores[index] += 2
			} else if len(term) >= 3 {
				for word in snippet.words {
					if !strings.has_prefix(word, term) do continue
					scores[index] += 1
					break
				}
			}
		}
	}
	if slice.max(scores) == 0 {
		for snippet, index in snippets {
			text := strings.to_lower(snippet.text, context.temp_allocator)
			for term in terms do if strings.contains(text, term) do scores[index] += 1
		}
	}

	best := slice.max(scores)
	found := make([dynamic]Snippet, context.temp_allocator)
	if best == 0 do return found[:]
	for snippet, index in snippets do if scores[index] == best do append(&found, snippet)
	return found[:]
}
