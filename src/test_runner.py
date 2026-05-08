#!/usr/bin/env python3

import os
import shutil
import subprocess
import time

def parse_schedule(schedule: str):
    tests = []
    for line in schedule.splitlines():
        label, name = line.split(':')
        if label == 'test':
            tests.append(name.strip())
    return tests

def run_test(test: str) -> bool:
    with (
        open(f'tests/sql/{test}.sql') as input_file,
        open(f'tests/results/{test}.out', 'w') as result_file
    ):
        os.makedirs('/tmp/datadir', exist_ok=True)

        server = subprocess.Popen(
            ["zig-out/bin/server"],
        )

        time.sleep(0.1)

        client = subprocess.Popen(
            ["zig-out/bin/client", "--no-prompt"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True
        )
        assert client.stdin is not None
        assert client.stdout is not None
        os.set_blocking(client.stdout.fileno(), False)

        try:
            for line in input_file:
                if line.strip() == '':
                    continue
                result_file.write('> ' + line)
                client.stdin.write(line.strip() + '\n')
                client.stdin.flush()
                time.sleep(0.1)
                output = client.stdout.readlines()
                print(output)
                for output_line in output:
                    result_file.write(output_line)
        finally:
            client.stdin.write('exit\n')
            client.wait()
            server.terminate()

        shutil.rmtree('/tmp/datadir')
        return True

def main():
    with open('tests/schedule.yaml') as file:
        schedule = file.read()
        schedule = parse_schedule(schedule)
    
    os.makedirs('tests/results', exist_ok=True)

    for test in schedule:
        result = run_test(test)
        print(f'{test:<10} : {'ok' if result else 'FAILED'}')

if __name__ == "__main__":
    main()