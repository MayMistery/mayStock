"""Public prediction-market research and local informational triggers.

This package has no account, credential, strategy, order or notification API.
"""

from .providers import PredictionError, PublicClient, Provider

__all__ = ["PredictionError", "PublicClient", "Provider"]
