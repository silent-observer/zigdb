#!/usr/bin/env python3

import os
import shutil
import difflib
import asyncio

def parse_schedule(schedule: str):
    tests = []
    for line in schedule.splitlines():
        label, name = line.split(':')
        if label == 'test':
            tests.append(name.strip())
    return tests

async def read_until_prompt(stdout: asyncio.StreamReader) -> str:
    output = ''
    while True:
        output += (await stdout.read(1024)).decode()
        if output.endswith('> '):
            return output.removesuffix('> ')

async def run_test(test: str) -> str:
    with (
        open(f'tests/sql/{test}.sql') as input_file,
        open(f'tests/results/{test}.out', 'w') as result_file
    ):
        try:
            shutil.rmtree('/tmp/datadir')
        except FileNotFoundError:
            pass
        os.makedirs('/tmp/datadir')

        server = await asyncio.subprocess.create_subprocess_exec(
            "zig-out/bin/server",
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL
        )

        await asyncio.sleep(0.1)

        client = await asyncio.subprocess.create_subprocess_exec(
            "zig-out/bin/client",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE
        )
        assert client.stdin is not None
        assert client.stdout is not None

        await read_until_prompt(client.stdout)

        try:
            for line in input_file:
                if line.strip() == '':
                    continue
                result_file.write('> ' + line)
                result_file.flush()
                client.stdin.write((line.strip() + '\n').encode())
                output = await read_until_prompt(client.stdout)
                result_file.write(output)
                result_file.flush()
        finally:
            client.stdin.write(b'exit\n')
            await client.wait()
            server.kill()

    with (
        open(f'tests/expected/{test}.out') as expected_file,
        open(f'tests/results/{test}.out') as result_file
    ):
        expected = expected_file.readlines()
        result = result_file.readlines()
        diff = difflib.unified_diff(expected, result, fromfile=f'tests/expected/{test}.out', tofile=f'tests/results/{test}.out')
        return ''.join(diff)

async def main():
    with open('tests/schedule.yaml') as file:
        schedule = file.read()
        schedule = parse_schedule(schedule)
    
    os.makedirs('tests/results', exist_ok=True)

    with open('tests/regression.diff', 'w') as file:
        for test in schedule:
            diff = await run_test(test)
            result = 'ok' if len(diff) == 0 else 'FAILED'
            print(f'{test:<10} : {result}')
            file.write(diff)
            file.flush()

if __name__ == "__main__":
    asyncio.run(main())