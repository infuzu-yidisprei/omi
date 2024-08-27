import { TranscriptSegment } from '@/src/types/memory.types';
import TranscriptionSegment from './transcription-segment';

interface TranscriptionProps {
  transcript: TranscriptSegment[];
}

export default function Transcription({ transcript }: TranscriptionProps) {
  const uniqueSpeakers = Array.from(
    new Set(transcript.map((segment) => segment.speaker_id)),
  );
  return (
    <div>
      <h3 className="mt-10 text-2xl font-semibold">Transcription</h3>
      <span className="text-base font-light text-gray-400">
        Total Speakers: {uniqueSpeakers.length}
      </span>
      <ul className="mt-4">
        {transcript.map((segment) => (
          <TranscriptionSegment key={segment.speaker_id} segment={segment} />
        ))}
      </ul>
    </div>
  );
}
