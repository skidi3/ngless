ngless "0.0"
write(count(annotate(map(fastq('../samples/sample_1.fq'),reference='sacCer3'), features=[{gene},{cds},{exon}], gff='../samples/genes.gff'), count={gene}, min=10), ofile="../samples/CountsResult.txt", format={tsv})