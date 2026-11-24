"""Minimal LangChain client for the Inkling 2 Mini endpoint (OpenAI-compatible).

Setup:
    pip install langchain-openai
    export INKLING_BASE_URL="https://inkling.<your-tailnet>.ts.net/v1"   # scripts/funnel.sh url
    export INKLING_API_KEY="sk-inkling-..."                             # scripts/keys.sh add <name>
    python examples/langchain_quickstart.py

Shows: a plain call, streaming, and tool calling.
"""
import os

from langchain_core.messages import HumanMessage, SystemMessage, ToolMessage
from langchain_core.tools import tool
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(
    model="inkling-2-mini",
    base_url=os.environ["INKLING_BASE_URL"],
    api_key=os.environ["INKLING_API_KEY"],
    # The model always reasons before answering. Without reasoning_effort it uses "high" (slow, long).
    # Options: none, minimal, low, medium, high, xhigh, max.
    reasoning_effort="low",
    # Reasoning tokens count toward max_tokens; leave room or the answer comes back empty.
    max_tokens=4096,
    temperature=1.0,  # the model's recommended default
    timeout=600,
    max_retries=2,
)

# 1) Plain call
reply = llm.invoke([
    SystemMessage("You are a concise assistant."),
    HumanMessage("Explain what a looped transformer is in two sentences."),
])
print("1) invoke:\n", reply.content, "\n   usage:", reply.usage_metadata, "\n")

# 2) Streaming: tokens print as they arrive
print("2) stream:")
for chunk in llm.stream("Give three tips for writing clear commit messages."):
    print(chunk.content, end="", flush=True)
print("\n")


# 3) Tool calling: the model asks for a tool, we run it, then it answers with the result
@tool
def get_weather(city: str) -> str:
    """Get the current weather for a city."""
    return f"It is 31°C and sunny in {city}."  # stand-in for a real API call


llm_with_tools = llm.bind_tools([get_weather])
messages = [HumanMessage("What's the weather in Pune right now?")]
ai = llm_with_tools.invoke(messages)
messages.append(ai)
for call in ai.tool_calls:
    print("3) tool call:", call["name"], call["args"])
    messages.append(ToolMessage(get_weather.invoke(call["args"]), tool_call_id=call["id"]))
print("   final answer:", llm_with_tools.invoke(messages).content)
