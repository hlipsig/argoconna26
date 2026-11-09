"""Preserve Responses text.format in the pinned LiteLLM ChatGPT adapter.

LiteLLM 1.106.4 filters `text` from its request allow-list. Holmes sends a JSON
schema via Chat Completions, which LiteLLM translates to Responses text.format.
The backend accepts it; preserve it instead of silently losing validation.
"""
from litellm.integrations.custom_logger import CustomLogger
from litellm.llms.chatgpt.responses.transformation import ChatGPTResponsesAPIConfig

_original = ChatGPTResponsesAPIConfig.transform_responses_api_request


def _with_schema(self, model, input, response_api_optional_request_params, litellm_params, headers):
    request = _original(self, model, input, response_api_optional_request_params, litellm_params, headers)
    if response_api_optional_request_params.get("text") is not None:
        request["text"] = response_api_optional_request_params["text"]
    return request


ChatGPTResponsesAPIConfig.transform_responses_api_request = _with_schema
# Import this module using LiteLLM's documented custom callback loader.
schema_compat = CustomLogger()
