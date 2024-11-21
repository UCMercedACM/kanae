from pydantic import BaseModel
from typing import Any, Mapping


class KanaeModel(BaseModel, Mapping):
    name: str

    def __getitem__(self, item: Any):
        return self.model_fields[item]

    def __len__(self) -> int:
        return len(self.model_fields)

    def __iter__(self):
        for k, item in self.model_fields.items():
            yield item


model = KanaeModel(name="gi")

print(*model.model_dump().values())
