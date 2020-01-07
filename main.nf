#!/bin/bash nextflow

/*
 * Copyright (c) 2019, Ontario Institute for Cancer Research (OICR).
 *                                                                                                               
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * Authors: Junjun Zhang <junjun.zhang@oicr.on.ca>
 *          Linda Xiang <linda.xiang@oicr.on.ca>
 */

nextflow.preview.dsl=2
name = 'dna-seq-alignment'

// params for starting from migrating legacy ICGC data
params.exp_tsv = ""
params.rg_tsv = ""
params.file_tsv = ""
params.token_file_legacy_data = ""

// params for starting from submitted ARGO data
params.seq_expriment_analysis_id = ""
params.program_id = "TEST-PRO"

// params for SONG / SCORE
params.token_file = ""
params.token_str = ""
params.song_url = "https://song.qa.argo.cancercollaboratory.org"
params.score_url = "https://score.qa.argo.cancercollaboratory.org"

// params for preprocessing: bam to ubam
params.reads_max_discard_fraction = 0.08

// params for alignment
params.ref_genome_fa = "tests/reference/tiny-grch38-chr11-530001-537000.fa"
params.cpus_align = -1  // negative means use default
params.cpus_mkdup = -1  // negative means use default
params.upload_ubam = false
params.markdup = true
params.lossy = false
params.aligned_seq_output_format = "bam"


include "./modules/raw.githubusercontent.com/icgc-argo/dna-seq-processing-tools/seq-data-to-lane-bam.0.1.6.0/tools/seq-data-to-lane-bam/seq-data-to-lane-bam.nf" params(params)
include "./modules/raw.githubusercontent.com/icgc-argo/dna-seq-processing-tools/bwa-mem-aligner.0.1.2.1/tools/bwa-mem-aligner/bwa-mem-aligner.nf" params(params)
include "./modules/raw.githubusercontent.com/icgc-argo/dna-seq-processing-tools/bam-merge-sort-markdup.0.1.4.1/tools/bam-merge-sort-markdup/bam-merge-sort-markdup.nf" params(params)
include GetAnalysisAndData from "./get-analysis-and-data/get-analysis-and-data.nf" params(params)

include SequencingDataSubmission as SequencingDataMigration from "./sequencing-data-submission/main.nf" params(
  "song_url": params.song_url, "score_url": params.score_url, "token_file": params.token_file,
  "token_file_legacy_data": params.token_file_legacy_data, "upload_files": false  // download data from legacy data repo to process but not upload to ARGO RDPC score
)

//include ReadGroupUbamUpload from "./read-group-ubam-upload/read-group-ubam-upload.nf" params(
//  "wf_name": name, "wf_version": workflow.manifest.version, "song_url": params.song_url,
//  "score_url": params.score_url, "token_file": params.token_file, "upload_ubam": params.upload_ubam
//)

include DnaAlignmentUpload from "./dna-alignment-upload/dna-alignment-upload.nf" params(
  "wf_name": name, "wf_version": workflow.manifest.version, "song_url": params.song_url,
  "score_url": params.score_url, "token_file": params.token_file
)

process genTokenFile {
  input:
    val token_str

  output:
    path "access_token", emit: token_file

  script:
    """
    echo ${token_str} > access_token
    """
}


workflow DnaSeqAlignmentWf {
  get:
    seq_expriment_analysis_id
    exp_tsv
    rg_tsv
    file_tsv
    reads_max_discard_fraction
    token_str

  main:
    genTokenFile(token_str)
    /*
     * Section 1:
     * migrate data from ICGC legacy repository or just get ARGO data already submitted to RDPC repository
     */
    if (seq_expriment_analysis_id.length() == 0) {  // start from migrating ICGC legacy data
      SequencingDataMigration(file(exp_tsv), file(rg_tsv), file(file_tsv))
      seq_expriment_analysis = SequencingDataMigration.out.seq_expriment_analysis
      files_to_process = SequencingDataMigration.out.files_to_submit

    } else {  // start from submitted ARGO data
      GetAnalysisAndData(seq_expriment_analysis_id, genTokenFile.out.token_file)
      seq_expriment_analysis = GetAnalysisAndData.out.analysis
      files_to_process = GetAnalysisAndData.out.files

    }

    /*
     * Section 2:
     * preprocessing input data into read group level unmapped BAM (uBAM)
     */
    // prepare unmapped BAM
    seqDataToLaneBam(seq_expriment_analysis, files_to_process.collect(), reads_max_discard_fraction)

    // create SONG entry for read group ubam (and upload data if upload_ubam set to true)
    //ReadGroupUbamUpload(seq_expriment_analysis,
    //    seqDataToLaneBam.out.lane_bams.flatten(), seqDataToLaneBam.out.lane_bams.collect())

    /*
     * Section 3:
     * aligning uBAM using BWA MEM in parallel and merge into single BAM for marking duplicated reads,
     * finally upload aligned seq back to SONG/SCORE
     */
    // BWA alignment for each ubam in scatter
    bwaMemAligner(seqDataToLaneBam.out.lane_bams.flatten(), "grch38-aligned",
        params.cpus_align, file(params.ref_genome_fa + ".gz"),
        Channel.fromPath(getBwaSecondaryFiles(params.ref_genome_fa + ".gz"), checkIfExists: true).collect())

    // merge aligned lane BAM and mark dups, convert to CRAM if specified
    bamMergeSortMarkdup(bwaMemAligner.out.aligned_bam.collect(), file(params.ref_genome_fa),
        Channel.fromPath(getFaiFile(params.ref_genome_fa), checkIfExists: true).collect(),
        params.cpus_mkdup, 'aligned_seq_basename', params.markdup,
        params.aligned_seq_output_format, params.lossy)

    // Create SONG entry for final aligned/merged BAM/CRAM and upload to SCORE server
    DnaAlignmentUpload(
        bamMergeSortMarkdup.out.merged_seq.concat(bamMergeSortMarkdup.out.merged_seq_idx).collect(),
        seq_expriment_analysis,
        genTokenFile.out.token_file
        )

  emit: // outputs
    seq_expriment_analysis = seq_expriment_analysis
    //read_group_ubam = seqDataToLaneBam.out.lane_bams
    //read_group_ubam_analysis = ReadGroupUbamUpload.out.read_group_ubam_analysis
    alignment_files = DnaAlignmentUpload.out.alignment_files
    dna_seq_alignment_analysis = DnaAlignmentUpload.out.dna_seq_alignment_analysis
}


workflow {
  main:
    DnaSeqAlignmentWf(
      params.seq_expriment_analysis_id,
      params.exp_tsv,
      params.rg_tsv,
      params.file_tsv,
      params.reads_max_discard_fraction,
      params.token_str
    )

  publish:
    DnaSeqAlignmentWf.out.seq_expriment_analysis to: "outdir", overwrite: true
    //DnaSeqAlignmentWf.out.read_group_ubam to: "outdir", overwrite: true
    //DnaSeqAlignmentWf.out.read_group_ubam_analysis to: "outdir", overwrite: true
    DnaSeqAlignmentWf.out.alignment_files to: "outdir", overwrite: true
    DnaSeqAlignmentWf.out.dna_seq_alignment_analysis to: "outdir", overwrite: true
}
