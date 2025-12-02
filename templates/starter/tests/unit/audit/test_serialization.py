"""Tests for audit middleware serialization utilities."""

from datetime import date, datetime
from decimal import Decimal
from enum import Enum
from uuid import uuid4

import pytest

from app.core.audit.middleware import _serialize_value


class SampleEnum(Enum):
    """Sample enum for serialization tests."""

    VALUE_A = "a"
    VALUE_B = 42


class TestSerializeValue:
    """Tests for _serialize_value function."""

    def test_serialize_none(self):
        """Verify None passes through unchanged."""
        assert _serialize_value(None) is None

    def test_serialize_string(self):
        """Verify strings pass through unchanged."""
        assert _serialize_value("hello") == "hello"
        assert _serialize_value("") == ""

    def test_serialize_int(self):
        """Verify integers pass through unchanged."""
        assert _serialize_value(42) == 42
        assert _serialize_value(0) == 0
        assert _serialize_value(-1) == -1

    def test_serialize_float(self):
        """Verify floats pass through unchanged."""
        assert _serialize_value(3.14) == 3.14
        assert _serialize_value(0.0) == 0.0

    def test_serialize_bool(self):
        """Verify booleans pass through unchanged."""
        assert _serialize_value(True) is True
        assert _serialize_value(False) is False

    def test_serialize_uuid(self):
        """Verify UUID is converted to string."""
        test_uuid = uuid4()
        result = _serialize_value(test_uuid)
        assert result == str(test_uuid)
        assert isinstance(result, str)

    def test_serialize_datetime(self):
        """Verify datetime is converted to ISO format."""
        dt = datetime(2024, 1, 15, 10, 30, 45)
        result = _serialize_value(dt)
        assert result == "2024-01-15T10:30:45"
        assert isinstance(result, str)

    def test_serialize_date(self):
        """Verify date is converted to ISO format."""
        d = date(2024, 1, 15)
        result = _serialize_value(d)
        assert result == "2024-01-15"
        assert isinstance(result, str)

    def test_serialize_decimal(self):
        """Verify Decimal is converted to string."""
        dec = Decimal("123.45")
        result = _serialize_value(dec)
        assert result == "123.45"
        assert isinstance(result, str)

    def test_serialize_enum(self):
        """Verify Enum is converted to its value."""
        assert _serialize_value(SampleEnum.VALUE_A) == "a"
        assert _serialize_value(SampleEnum.VALUE_B) == 42

    def test_serialize_dict(self):
        """Verify dict values are recursively serialized."""
        test_uuid = uuid4()
        data = {
            "id": test_uuid,
            "name": "test",
            "count": 5,
        }
        result = _serialize_value(data)

        assert result == {
            "id": str(test_uuid),
            "name": "test",
            "count": 5,
        }

    def test_serialize_nested_dict(self):
        """Verify nested dicts are recursively serialized."""
        test_uuid = uuid4()
        data = {
            "outer": {
                "inner": {
                    "id": test_uuid,
                }
            }
        }
        result = _serialize_value(data)

        assert result["outer"]["inner"]["id"] == str(test_uuid)

    def test_serialize_list(self):
        """Verify list items are recursively serialized."""
        test_uuid = uuid4()
        data = [test_uuid, "string", 42]
        result = _serialize_value(data)

        assert result == [str(test_uuid), "string", 42]
        assert isinstance(result, list)

    def test_serialize_tuple(self):
        """Verify tuple items are serialized to list."""
        test_uuid = uuid4()
        data = (test_uuid, "string", 42)
        result = _serialize_value(data)

        assert result == [str(test_uuid), "string", 42]
        assert isinstance(result, list)

    def test_serialize_set(self):
        """Verify set items are serialized to list."""
        data = {1, 2, 3}
        result = _serialize_value(data)

        assert isinstance(result, list)
        assert sorted(result) == [1, 2, 3]

    def test_serialize_frozenset(self):
        """Verify frozenset items are serialized to list."""
        data = frozenset([1, 2, 3])
        result = _serialize_value(data)

        assert isinstance(result, list)
        assert sorted(result) == [1, 2, 3]

    def test_serialize_unknown_type_converts_to_string(self):
        """Verify unknown types are converted to string."""

        class CustomClass:
            def __str__(self):
                return "custom_object"

        obj = CustomClass()
        result = _serialize_value(obj)

        assert result == "custom_object"
        assert isinstance(result, str)

    def test_serialize_complex_structure(self):
        """Verify complex nested structures are fully serialized."""
        test_uuid = uuid4()
        dt = datetime(2024, 1, 15, 10, 30, 0)

        data = {
            "users": [
                {"id": test_uuid, "created": dt},
                {"id": uuid4(), "status": SampleEnum.VALUE_A},
            ],
            "metadata": {
                "amount": Decimal("99.99"),
                "tags": ["a", "b"],
            },
        }

        result = _serialize_value(data)

        # Check structure is correct
        assert isinstance(result["users"], list)
        assert result["users"][0]["id"] == str(test_uuid)
        assert result["users"][0]["created"] == "2024-01-15T10:30:00"
        assert result["users"][1]["status"] == "a"
        assert result["metadata"]["amount"] == "99.99"
        assert result["metadata"]["tags"] == ["a", "b"]
