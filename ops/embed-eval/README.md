# Embedding eval

`corpus.py` is one Russian Telegram user's memory bank (120 facts, 13 deliberate look-alikes)
with 84 colloquial queries. `eval.py <druzhok base> <FETCH_SECRET>` embeds it through
`POST /internal/embed` and prints R@1, R@5, MRR and how often a look-alike outranks the answer.

Reference for fp32 multilingual-e5-small: `R@1=0.80 R@5=0.95 MRR=0.87 hardneg_wins=2/44`.
Swap in the int8 model (`model_qint8_avx512_vnni.onnx`) only if R@5 stays within 0.02 of that.
