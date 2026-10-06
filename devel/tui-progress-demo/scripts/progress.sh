# Sourced by demo scripts — provides aba_progress()
# In real ABA this would live in include_all.sh
aba_progress() {
	[ -n "${ABA_PROGRESS_FIFO:-}" ] || return 0
	printf '%s\n' "$*" >> "$ABA_PROGRESS_FIFO"
}
