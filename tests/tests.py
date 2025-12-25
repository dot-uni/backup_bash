import os
import time
import subprocess
from random import randrange, choice
from itertools import combinations

# ---------- SETTING ----------
EXTENSIONS = ['.doc', '.docx', '.xls', '.xlsx', '.log', '.db']
TEST_PATH = "./test_data/"            # Путь до тестового набора, который хранится в папке test_data
BACKUP_SCRIPT = "./backup.sh"         # Путь до backup.sh (ТРЕБУЕТСЯ УКАЗАТЬ)
BACKUP_DIR = os.path.expanduser('~')  # Путь до директории, в которой будет создан бэкап

os.makedirs(TEST_PATH, exist_ok=True)

def generate_test_files():
    """Генерация случайных файлов для теста"""
    for ext in choice(list(combinations(EXTENSIONS, 3))):
        for i in range(randrange(3, 10)):
            name = ''.join([chr(randrange(0x61, 0x7a)) for _ in range(randrange(6, 10))])
            filepath = os.path.join(TEST_PATH, name + ext)
            with open(filepath, 'w+') as hfile:
                hfile.write(f"Test content {randrange(1000)}\n")

def run_backup(mode="incremental", compress_flag=None):
    """Запуск скрипта резервного копирования"""
    cmd = [BACKUP_SCRIPT]
    if mode:
        cmd += ["-m", mode]
    if compress_flag:
        cmd += [compress_flag]
    cmd += ["-d", BACKUP_DIR]
    cmd += [TEST_PATH]
    print(f"Running backup: {' '.join(cmd)}")
    subprocess.run(cmd, check=True)

# ---------- TESTS ----------


# 1. Генерация тестовых файлов
generate_test_files()
print("Generated test files.")

# 2. Compressed backup
run_backup(mode="incremental", compress_flag="-c")
time.sleep(1)
run_backup(mode="incremental", compress_flag="-cz6")
time.sleep(1)
run_backup(mode="full", compress_flag="-cj9")
time.sleep(1)
run_backup(mode="mirror", compress_flag="-cJ")
time.sleep(1)

# 3. Full backup
run_backup(mode="full")
time.sleep(1)

# 4. Incremental backup с изменением файлов
new_file = os.path.join(TEST_PATH, "new_incremental.log")
with open(new_file, 'w') as f:
    f.write("Incremental test file\n")
run_backup(mode="incremental")
time.sleep(1)

# 5. Mirror backup после удаления файла
if os.path.exists(new_file):
    os.remove(new_file)
run_backup(mode="mirror")

# 6. Проверка коректности работы при бэкапе двух файлов с одним и тем же названием одновременно
# В предыдущих тестах мы явно исключали случаи создания таких директорий с помощью sleep, чтобы тесты коректно работали 
# Ожидаемый результат выполнения комнады: ERROR: Failed to create directory...
try:
    run_backup(mode="full")
    print("Test failed")
except subprocess.CalledProcessError as e:
    print(f"The test was successfully completed. Backup failed with return code {e.returncode}")
    print(f"Command: {e.cmd}")