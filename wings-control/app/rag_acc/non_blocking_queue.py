import asyncio
import collections


class NonBlockingQueue:
    def __init__(self):
        self._queue = collections.deque()
        self._lock = asyncio.Lock()
        self._not_empty = asyncio.Event()
        self._finished = False

    def qsize(self):
        return len(self._queue)

    def empty(self):
        return len(self._queue) == 0

    async def put(self, item):
        async with self._lock:
            self._queue.append(item)
            self._not_empty.set()

    def get_nowait(self):
        if self.empty():
            raise asyncio.QueueEmpty
        item = self._queue.popleft()
        if self.empty():
            self._not_empty.clear()
        return item

    def peek_nowait(self):
        if self.empty():
            raise asyncio.QueueEmpty
        return self._queue[0]

    async def get(self):
        while True:
            try:
                return self.get_nowait()
            except asyncio.QueueEmpty:
                self._not_empty.clear()
                await self._not_empty.wait()

    def finish(self):
        self._finished = True

    def is_finished(self):
        return self._finished and self.empty()

    def prepend(self, item):
        self._queue.appendleft(item)
        self._not_empty.set()
