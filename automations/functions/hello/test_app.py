import unittest

from app import handler


class HelloTest(unittest.TestCase):
    def test_greets_the_name(self):
        self.assertEqual(handler({"name": "censhare"}, None), {"greeting": "Hello, censhare"})

    def test_greets_the_world_without_a_name(self):
        self.assertEqual(handler({}, None), {"greeting": "Hello, world"})


if __name__ == "__main__":
    unittest.main()
