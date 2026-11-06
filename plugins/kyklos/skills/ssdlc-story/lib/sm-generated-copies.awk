# sm-generated-copies.awk - print each input file whose first `lines` lines carry the generated-copy banner, once.
# One process for any number of files (the story tool checks every story folder after each mirror write).
# Usage: awk -v lines=<N> -v pat='<extended regex>' -f sm-generated-copies.awk FILE...
FNR <= lines && $0 ~ pat && !(FILENAME in hit) { hit[FILENAME] = 1; print FILENAME }
