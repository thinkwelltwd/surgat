from setuptools import setup, find_packages
from os import path
from surgat import __version__
import io
from glob import glob


here = path.abspath(path.dirname(__file__))

# Get the long description from the relevant file
with io.open(path.join(here, 'README.md'), encoding='utf-8') as f:
    long_description = f.read()

setup(
    name='surgat',
    version=__version__,
    description='Transparent Mail Proxy for postfix and spamassasin',
    long_description=long_description,
    url='https://github.com/zathras777/surgat',
    author='david reid',
    author_email='zathrasorama@gmail.com',
    license='Unlicense',
    classifiers=[
        'Development Status :: 3 - Alpha',
        'Intended Audience :: Developers',
        'Topic :: Software Development :: Libraries :: Python Modules',
        'Programming Language :: Python :: 2.7',
        'Programming Language :: Python :: 3.4',
    ],
    keywords='mail postfix spamassassin daemon',
    data_files=[('/usr/local/etc', glob("conf/*"))],
    packages=find_packages(exclude=['tests']),
    test_suite='tests',
    entry_points={
        'console_scripts': ['surgat=surgat.command_line:main',
                            'surgat-replay=surgat.command_line:replay']
    },
    install_requires=['spamc', 'daemonize']
)

