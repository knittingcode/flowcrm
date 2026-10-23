<?php

declare(strict_types=1);

namespace App\Identity\Infrastructure\Console;

use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\StreamableInputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Question\Question;
use Symfony\Component\Console\Style\SymfonyStyle;

/**
 * Reads a password for an operator command: from standard input, one line
 * (for example `printf '%s\n' "$password" | bin/console …`), or hidden at a
 * terminal. Never from an argument or an option, which other users of the
 * host could read in the process list, and it is never printed.
 */
final class PasswordInput
{
    public static function read(InputInterface $input, OutputInterface $output): ?string
    {
        $stream = $input instanceof StreamableInputInterface ? $input->getStream() : null;
        $stream ??= \STDIN;

        if (stream_isatty($stream)) {
            $question = new Question('Password (12 to 128 characters, input hidden)');
            $question->setHidden(true)->setHiddenFallback(false)->setTrimmable(false);
            $value = new SymfonyStyle($input, $output)->askQuestion($question);

            return \is_string($value) ? $value : null;
        }

        $line = fgets($stream);

        return false === $line ? null : rtrim($line, "\r\n");
    }
}
