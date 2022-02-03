#!/bin/bash
# Description: AlphaFold-Multimer (Non-Docker)
# Original Author: Sanjay Kumar Srikakulam
# Latest Author: Alex Morehead

usage() {
  echo ""
  echo "Please make sure all required parameters are given"
  echo "Usage: $0 <OPTIONS>"
  echo "Required Parameters:"
  echo "-d <data_dir>     Path to directory with supporting data: AlphaFold parameters and genetic and template databases. Set to the target of download_all_databases.sh."
  echo "-o <output_dir>   Path to a directory that will store the results."
  echo "-f <fasta_path>   Path to a FASTA file containing one sequence."
  echo "-t <max_template_date> Maximum template release date to consider (ISO-8601 format: YYYY-MM-DD). Important if folding historical test sets."
  echo "Optional Parameters:"
  echo "-n <openmm_threads>   OpenMM threads (default: all available cores)"
  echo "-b <benchmark>    Run multiple JAX model evaluations to obtain a timing that excludes the compilation time, which should be more indicative of the time required for inferencing many proteins (default: false)"
  echo "-g <use_gpu>      Enable NVIDIA runtime to run with GPUs (default: true)"
  echo "-a <gpu_devices>  Comma separated list of devices to pass to 'CUDA_VISIBLE_DEVICES' (default: 0)"
  echo "-m <model_preset>  Choose preset model configuration - the monomer model (monomer), the monomer model with extra ensembling (monomer_casp14), monomer model with pTM head (monomer_ptm), or multimer model (multimer) (default: monomer)"
  echo "-p <db_preset>       Choose preset MSA database configuration - smaller genetic database config (reduced_dbs) or full genetic database config (full_dbs) (default: full_dbs)"
  echo "-u <use_precomputed_msas>       Whether to read MSAs that have been written to disk. WARNING: This will not check if the sequence, database or configuration have changed. (default: false)"
  echo "-r <remove_msas_after_use>       Whether, after structure prediction(s), to delete MSAs that have been written to disk to significantly free up storage space. (default: false)"
  echo "-i <is_prokaryote>   Optional for multimer system, not used by the single chain system. This should contain a boolean specifying true where the target complex is from a prokaryote, and false where it is not, or where the origin is unknown. These values determine the pairing method for the MSA (default: false)"
  echo ""
  exit 1
}

while getopts ":d:o:f:t:n:b:g:a:m:p:u:r:i" i; do
  case "${i}" in
  d)
    data_dir=$OPTARG
    ;;
  o)
    output_dir=$OPTARG
    ;;
  f)
    fasta_path=$OPTARG
    ;;
  t)
    max_template_date=$OPTARG
    ;;
  n)
    openmm_threads=$OPTARG
    ;;
  b)
    benchmark=$OPTARG
    ;;
  g)
    use_gpu=$OPTARG
    ;;
  a)
    gpu_devices=$OPTARG
    ;;
  m)
    model_preset=$OPTARG
    ;;
  p)
    db_preset=$OPTARG
    ;;
  u)
    use_precomputed_msas=$OPTARG
    ;;
  r)
    remove_msas_after_use=$OPTARG
    ;;
  i)
    is_prokaryote=$OPTARG
    ;;
  esac
done

# Parse input and set defaults
if [[ "$data_dir" == "" || "$output_dir" == "" || "$fasta_path" == "" || "$max_template_date" == "" ]]; then
  usage
fi

if [[ "$benchmark" == "" ]]; then
  benchmark=false
fi

if [[ "$use_gpu" == "" ]]; then
  use_gpu=true
fi

if [[ "$gpu_devices" == "" ]]; then
  gpu_devices=0
fi

if [[ "$model_preset" == "" ]]; then
  model_preset="monomer"
fi

if [[ "$db_preset" == "" ]]; then
  db_preset="full_dbs"
fi

if [[ "$use_precomputed_msas" == "" ]]; then
  use_precomputed_msas=false
fi

if [[ "$remove_msas_after_use" == "" ]]; then
  remove_msas_after_use=false
fi

if [[ "$is_prokaryote" == "" ]]; then
  is_prokaryote=false
fi

if [[ "$db_preset" != "full_dbs" && "$db_preset" != "reduced_dbs" ]]; then
  echo "Unknown preset database! Using default ('full_dbs')"
  db_preset="full_dbs"
fi


current_working_dir=$(pwd)
#JAB - Add script directory so we do not need to run from alphafold directory
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
alphafold_script="$SCRIPT_DIR/run_alphafold.py"

if [ ! -f "$alphafold_script" ]; then
  echo "Alphafold python script $alphafold_script does not exist."
  exit 1
fi

# Export ENVIRONMENT variables and set CUDA devices for use
# CUDA GPU control
export CUDA_VISIBLE_DEVICES=-1
if [[ "$use_gpu" == true ]]; then
  export CUDA_VISIBLE_DEVICES=0

  if [[ "$gpu_devices" ]]; then
    export CUDA_VISIBLE_DEVICES=$gpu_devices
  fi
fi

# OpenMM threads control
if [[ "$openmm_threads" ]]; then
  export OPENMM_CPU_THREADS=$openmm_threads
fi

# TensorFlow control
export TF_FORCE_UNIFIED_MEMORY='1'

# JAX control
export XLA_PYTHON_CLIENT_MEM_FRACTION='4.0'

# Path and user config (change if required)
bfd_database_path="$data_dir/bfd/bfd_metaclust_clu_complete_id30_c90_final_seq.sorted_opt"
small_bfd_database_path="$data_dir/small_bfd/bfd-first_non_consensus_sequences.fasta"
mgnify_database_path="$data_dir/mgnify/mgy_clusters.fa"
template_mmcif_dir="$data_dir/pdb_mmcif/mmcif_files"
obsolete_pdbs_path="$data_dir/pdb_mmcif/obsolete.dat"
pdb70_database_path="$data_dir/pdb70/pdb70"
pdb_seqres_database_path="$data_dir/pdb_seqres/pdb_seqres.txt"
uniclust30_database_path="$data_dir/uniclust30/uniclust30_2018_08/uniclust30_2018_08"
uniprot_database_path="$data_dir/uniprot/uniprot.fasta"
uniref90_database_path="$data_dir/uniref90/uniref90.fasta"

# Binary path (change if required)
hhblits_binary_path=$(which hhblits)
hhsearch_binary_path=$(which hhsearch)
jackhmmer_binary_path=$(which jackhmmer)
kalign_binary_path=$(which kalign)

# Run AlphaFold with required parameters
# 'reduced_dbs' preset database does not use bfd and uniclust30 databases
if [[ "$db_preset" == "reduced_dbs" && "$model_preset" == "monomer" ]]; then
  $(python $alphafold_script --hhblits_binary_path=$hhblits_binary_path --hhsearch_binary_path=$hhsearch_binary_path --jackhmmer_binary_path=$jackhmmer_binary_path --kalign_binary_path=$kalign_binary_path --small_bfd_database_path=$small_bfd_database_path --mgnify_database_path=$mgnify_database_path --template_mmcif_dir=$template_mmcif_dir --obsolete_pdbs_path=$obsolete_pdbs_path --pdb70_database_path=$pdb70_database_path --uniref90_database_path=$uniref90_database_path --data_dir=$data_dir --output_dir=$output_dir --fasta_paths=$fasta_path --max_template_date=$max_template_date --model_preset=$model_preset --db_preset=$db_preset --benchmark=$benchmark --use_precomputed_msas=$use_precomputed_msas --remove_msas_after_use=$remove_msas_after_use --logtostderr)
elif [[ "$db_preset" == "reduced_dbs" ]]; then
  $(python $alphafold_script --hhblits_binary_path=$hhblits_binary_path --hhsearch_binary_path=$hhsearch_binary_path --jackhmmer_binary_path=$jackhmmer_binary_path --kalign_binary_path=$kalign_binary_path --small_bfd_database_path=$small_bfd_database_path --mgnify_database_path=$mgnify_database_path --template_mmcif_dir=$template_mmcif_dir --obsolete_pdbs_path=$obsolete_pdbs_path --pdb_seqres_database_path=$pdb_seqres_database_path --uniprot_database_path=$uniprot_database_path --uniref90_database_path=$uniref90_database_path --data_dir=$data_dir --output_dir=$output_dir --fasta_paths=$fasta_path --max_template_date=$max_template_date --model_preset=$model_preset --db_preset=$db_preset --benchmark=$benchmark --use_precomputed_msas=$use_precomputed_msas --remove_msas_after_use=$remove_msas_after_use --logtostderr --is_prokaryote_list=$is_prokaryote)
elif [[ "$db_preset" == "full_dbs" && "$model_preset" == "monomer" ]]; then
  $(python $alphafold_script --hhblits_binary_path=$hhblits_binary_path --hhsearch_binary_path=$hhsearch_binary_path --jackhmmer_binary_path=$jackhmmer_binary_path --kalign_binary_path=$kalign_binary_path --bfd_database_path=$bfd_database_path --mgnify_database_path=$mgnify_database_path --template_mmcif_dir=$template_mmcif_dir --obsolete_pdbs_path=$obsolete_pdbs_path --pdb70_database_path=$pdb70_database_path --uniclust30_database_path=$uniclust30_database_path --uniref90_database_path=$uniref90_database_path --data_dir=$data_dir --output_dir=$output_dir --fasta_paths=$fasta_path --max_template_date=$max_template_date --model_preset=$model_preset --db_preset=$db_preset --benchmark=$benchmark --use_precomputed_msas=$use_precomputed_msas --remove_msas_after_use=$remove_msas_after_use --logtostderr)
else
  $(python $alphafold_script --hhblits_binary_path=$hhblits_binary_path --hhsearch_binary_path=$hhsearch_binary_path --jackhmmer_binary_path=$jackhmmer_binary_path --kalign_binary_path=$kalign_binary_path --bfd_database_path=$bfd_database_path --mgnify_database_path=$mgnify_database_path --template_mmcif_dir=$template_mmcif_dir --obsolete_pdbs_path=$obsolete_pdbs_path --pdb_seqres_database_path=$pdb_seqres_database_path --uniclust30_database_path=$uniclust30_database_path --uniprot_database_path=$uniprot_database_path --uniref90_database_path=$uniref90_database_path --data_dir=$data_dir --output_dir=$output_dir --fasta_paths=$fasta_path --max_template_date=$max_template_date --model_preset=$model_preset --db_preset=$db_preset --benchmark=$benchmark --use_precomputed_msas=$use_precomputed_msas --remove_msas_after_use=$remove_msas_after_use --logtostderr --is_prokaryote_list=$is_prokaryote)
fi
