#!/usr/bin/env python3

import os
import shutil
import difflib
import asyncio
import random
import re

def parse_schedule(schedule: str):
    tests = []
    for line in schedule.splitlines():
        label, name = line.split(':')
        if label == 'test':
            tests.append(name.strip())
    return tests

async def start_client(port: int) -> asyncio.subprocess.Process:
    client = await asyncio.subprocess.create_subprocess_exec(
            "zig-out/bin/client",
            "-p", str(port),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE
        )
    assert client.stdin is not None
    assert client.stdout is not None

    await read_until_prompt(client.stdout)
    return client

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

        port = random.randint(17300, 17400)

        server = await asyncio.subprocess.create_subprocess_exec(
            "zig-out/bin/server",
            "-p", str(port),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL
        )

        await asyncio.sleep(0.5)

        clients = dict()
        clients[0] = await start_client(port)

        try:
            for line in input_file:
                if line.strip() == '':
                    result_file.write(f'\n')
                    continue
                
                client_id = 0
                background = False
                background_check = False
                wait = False
                sql = line.strip() + '\n'

                match = re.match(r'^([0-9]+)([W&]?):(.*)$', line)
                
                if match:
                    client_id = int(match.group(1))
                    if client_id not in clients:
                        clients[client_id] = await start_client(port)
                    
                    if match.group(2) == '&':
                        background = True
                    elif match.group(2) == 'W':
                        wait = True

                    sql = match.group(3).strip() + '\n'
                    if background and sql == '\n':
                        background_check = True
                
                client = clients[client_id]

                if wait:
                    result_file.write(f'{client_id}W>\n')
                    result_file.flush()
                else:
                    if client_id > 0 or background:
                        bg = '&' if background else ''
                        if background_check:
                            sql = ''
                        result_file.write(f'{client_id}{bg}> {sql}')
                    else:
                        result_file.write(f'> {sql}')
                    result_file.flush()
                    if not background_check:
                        client.stdin.write(sql.encode())

                if background:
                    await asyncio.sleep(0.1)
                    if background_check:
                        if len(client.stdout._buffer) == 0:
                            result_file.write('...still waiting...\n')
                        else:
                            result_file.write('Got something!\n')
                    else:
                        result_file.write('...waiting...\n')
                    result_file.flush()
                else:
                    output = await read_until_prompt(client.stdout)
                    result_file.write(output)
                    result_file.flush()

        finally:
            for client in clients.values():
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
        errors = 0
        total = 0
        for test in schedule:
            diff = await run_test(test)
            result = '\033[32mok\033[0m' if len(diff) == 0 else '\033[31mFAILED\033[0m'
            print(f'{test:<10} : {result}')
            file.write(diff)
            file.flush()
            total += 1
            if len(diff) > 0:
                errors += 1
        if errors > 0:
            print(f'{errors} tests out of {total} failed')
        else:
            print(f'All {total} tests successful')

if __name__ == "__main__":
    asyncio.run(main())