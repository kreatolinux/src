import strutils

proc fuzzyMatch*(pattern, text: string): float =
  ## Simple fuzzy matching algorithm.
  ## Returns a score between 0.0 and 1.0, where 1.0 is a perfect match.
  if pattern.len == 0:
    return 1.0
  if text.len == 0:
    return 0.0

  let
    patternLower = pattern.toLowerAscii()
    textLower = text.toLowerAscii()

  # Check for exact substring match first
  if textLower.contains(patternLower):
    return 1.0

  var
    patternIdx = 0
    matchCount = 0
    consecutiveBonus = 0.0
    lastMatchIdx = -2

  for i, c in textLower:
    if patternIdx < patternLower.len and c == patternLower[patternIdx]:
      inc matchCount
      # Bonus for consecutive matches
      if i == lastMatchIdx + 1:
        consecutiveBonus += 0.1
      lastMatchIdx = i
      inc patternIdx

  if patternIdx < patternLower.len:
    # Not all pattern characters were found
    return 0.0

  # Calculate score based on:
  # - Ratio of matched characters to pattern length
  # - Consecutive match bonus
  # - Penalty for longer text (prefer shorter matches)
  let
    baseScore = matchCount.float / patternLower.len.float
    lengthPenalty = 1.0 - (text.len - pattern.len).float / (text.len.float * 2)
    finalScore = (baseScore * 0.6 + consecutiveBonus.min(0.2) + lengthPenalty * 0.2)

  return finalScore.min(1.0).max(0.0)
