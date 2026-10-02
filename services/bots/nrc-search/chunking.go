package main

import "strings"

const (
	chunkTargetWords  = 700
	chunkMaxWords     = 1024
	chunkOverlapWords = 120
)

type DocumentChunk struct {
	Index int
	Text  string
}

func chunkDocumentForEmbedding(content string) []DocumentChunk {
	texts := chunkDocumentText(content, chunkTargetWords, chunkMaxWords, chunkOverlapWords)
	chunks := make([]DocumentChunk, 0, len(texts))
	for i, text := range texts {
		chunks = append(chunks, DocumentChunk{Index: i, Text: text})
	}
	return chunks
}

func chunkDocumentText(text string, targetWords, maxWords, overlapWords int) []string {
	text = normalizeChunkText(text)
	if text == "" {
		return nil
	}
	if targetWords <= 0 {
		return []string{text}
	}
	if maxWords < targetWords {
		maxWords = targetWords
	}
	if overlapWords < 0 {
		overlapWords = 0
	}
	if overlapWords >= targetWords {
		overlapWords = targetWords / 4
	}

	blocks := splitDocumentBlocks(text, targetWords, maxWords)
	chunks := packChunkBlocks(blocks, targetWords, maxWords)
	return addChunkOverlap(chunks, overlapWords)
}

func normalizeChunkText(text string) string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	return strings.TrimSpace(text)
}

func splitDocumentBlocks(text string, targetWords, maxWords int) []string {
	paragraphs := splitParagraphs(text)
	blocks := make([]string, 0, len(paragraphs))
	headingPath := ""

	for _, para := range paragraphs {
		if isMarkdownHeading(para) {
			headingPath = strings.TrimSpace(strings.TrimLeft(para, "#"))
			continue
		}

		block := para
		if headingPath != "" {
			block = "section: " + headingPath + "\n" + para
		}

		if countWords(block) <= maxWords {
			blocks = append(blocks, block)
			continue
		}
		blocks = append(blocks, splitOversizedBlock(block, targetWords, maxWords)...)
	}
	return blocks
}

func splitParagraphs(text string) []string {
	parts := strings.Split(text, "\n\n")
	paragraphs := make([]string, 0, len(parts))
	for _, part := range parts {
		lines := strings.Split(part, "\n")
		for i := range lines {
			lines[i] = strings.TrimSpace(lines[i])
		}
		para := strings.TrimSpace(strings.Join(lines, "\n"))
		if para != "" {
			paragraphs = append(paragraphs, para)
		}
	}
	return paragraphs
}

func isMarkdownHeading(text string) bool {
	text = strings.TrimSpace(text)
	if !strings.HasPrefix(text, "#") {
		return false
	}
	level := 0
	for level < len(text) && text[level] == '#' {
		level++
	}
	return level > 0 && level <= 6 && level < len(text) && text[level] == ' '
}

func splitOversizedBlock(block string, targetWords, maxWords int) []string {
	sentences := splitSentences(block)
	if len(sentences) <= 1 {
		return chunkWordsWithOverlap(block, targetWords, 0)
	}

	blocks := make([]string, 0, len(sentences))
	current := ""
	for _, sentence := range sentences {
		if countWords(sentence) > maxWords {
			if current != "" {
				blocks = append(blocks, current)
				current = ""
			}
			blocks = append(blocks, chunkWordsWithOverlap(sentence, targetWords, 0)...)
			continue
		}
		if current == "" {
			current = sentence
			continue
		}
		candidate := current + " " + sentence
		if countWords(candidate) > targetWords {
			blocks = append(blocks, current)
			current = sentence
		} else {
			current = candidate
		}
	}
	if current != "" {
		blocks = append(blocks, current)
	}
	return blocks
}

func splitSentences(text string) []string {
	fields := strings.Fields(text)
	if len(fields) == 0 {
		return nil
	}

	sentences := make([]string, 0, 4)
	start := 0
	for i, field := range fields {
		if strings.HasSuffix(field, ".") || strings.HasSuffix(field, "!") || strings.HasSuffix(field, "?") {
			sentences = append(sentences, strings.Join(fields[start:i+1], " "))
			start = i + 1
		}
	}
	if start < len(fields) {
		sentences = append(sentences, strings.Join(fields[start:], " "))
	}
	return sentences
}

func packChunkBlocks(blocks []string, targetWords, maxWords int) []string {
	chunks := make([]string, 0, len(blocks))
	current := ""
	for _, block := range blocks {
		if current == "" {
			current = block
			continue
		}

		candidate := current + "\n\n" + block
		if countWords(candidate) > targetWords || countWords(candidate) > maxWords {
			chunks = append(chunks, current)
			current = block
		} else {
			current = candidate
		}
	}
	if current != "" {
		chunks = append(chunks, current)
	}
	return chunks
}

func addChunkOverlap(chunks []string, overlapWords int) []string {
	if overlapWords <= 0 || len(chunks) <= 1 {
		return chunks
	}
	out := make([]string, len(chunks))
	out[0] = chunks[0]
	for i := 1; i < len(chunks); i++ {
		overlap := trailingWords(chunks[i-1], overlapWords)
		if overlap == "" {
			out[i] = chunks[i]
		} else {
			out[i] = overlap + " " + chunks[i]
		}
	}
	return out
}

func countWords(text string) int {
	return len(strings.Fields(text))
}

func trailingWords(text string, n int) string {
	words := strings.Fields(text)
	if len(words) <= n {
		return strings.Join(words, " ")
	}
	return strings.Join(words[len(words)-n:], " ")
}

func chunkWordsWithOverlap(text string, chunkWords, overlapWords int) []string {
	words := strings.Fields(text)
	if len(words) == 0 {
		return nil
	}
	if chunkWords <= 0 || len(words) <= chunkWords {
		return []string{strings.Join(words, " ")}
	}
	if overlapWords < 0 {
		overlapWords = 0
	}
	if overlapWords >= chunkWords {
		overlapWords = chunkWords / 4
	}

	step := chunkWords - overlapWords
	chunks := make([]string, 0, (len(words)+step-1)/step)
	for start := 0; start < len(words); start += step {
		end := start + chunkWords
		if end > len(words) {
			end = len(words)
		}
		chunks = append(chunks, strings.Join(words[start:end], " "))
		if end == len(words) {
			break
		}
	}
	return chunks
}
