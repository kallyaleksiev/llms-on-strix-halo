#!/bin/bash

mkdir test && cd test

uv venv 

uv pip install \
  --index-url https://rocm.nightlies.amd.com/v2/gfx1151/ \
  "rocm[libraries,devel]"

uv pip install \
  --index-url https://rocm.nightlies.amd.com/v2/gfx1151/ \
  --pre torch

uv pip install transformers accelerate

uv run python <<'PY'
from transformers import AutoModelForCausalLM, AutoTokenizer
import torch

print("Loading Qwen/Qwen3-1.7B model...")
model_name = "Qwen/Qwen3-1.7B"
tokenizer = AutoTokenizer.from_pretrained(model_name)
model = AutoModelForCausalLM.from_pretrained(
    model_name,
    dtype=torch.bfloat16,
).to("cuda:0")

print("\nRunning inference...")
prompt = "What is the capital of Bulgaria?"
inputs = tokenizer(prompt, return_tensors="pt").to(model.device)

outputs = model.generate(
    **inputs,
    max_new_tokens=100,
    do_sample=True,
    temperature=0.7,
    top_p=0.95
)

response = tokenizer.decode(outputs[0], skip_special_tokens=True)
print(f"\nPrompt: {prompt}")
print(f"Response: {response}")
PY
