import sqlite3


def get_compile_options(cursor):
    cursor.execute("PRAGMA compile_options;")
    return cursor.fetchall()


def main():
    conn = sqlite3.connect(":memory:")
    cursor = conn.cursor()

    # Get the list of all compile options
    options_list = get_compile_options(cursor)

    # Print each compile option
    for option in options_list:
        print(f"{option[0]}")

    # Close the connection
    conn.close()


if __name__ == "__main__":
    main()
