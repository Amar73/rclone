#!/bin/bash
echo "Введите имя файла:"
read filename
if [ -f "$filename" ]; then
	echo "Файл $filename уже существует!"
else
	touch "$filename"
	echo "Файл $filename создан."
fi
